package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
)

// ExitUnavailable is EX_TEMPFAIL. A run refused because every subscription is spent is
// not a failure of the request — an application that queues on this exit code and the
// retryAfter beside it gets the work done later rather than losing it.
const ExitUnavailable = 75

type unavailable struct{ message string }

func (e *unavailable) Error() string { return e.message }

func exitCode(err error) int {
	var refused *unavailable
	if ok := asUnavailable(err, &refused); ok {
		return ExitUnavailable
	}
	return 1
}

func asUnavailable(err error, target **unavailable) bool {
	if cast, ok := err.(*unavailable); ok {
		*target = cast
		return true
	}
	return false
}

// runShim starts a session and becomes claude.
func runShim(args []string) error {
	cfg, rest, err := config.Load(args, os.Getenv)
	if err != nil {
		return err
	}
	launch, claudeArgs, err := splitRunArgs(rest)
	if err != nil {
		return err
	}
	claudeArgs = withModel(launch.Model, claudeArgs)
	// exec, not spawn: the pid the agent is told about has to end up being claude's,
	// because that is what it checks to know the run is still alive.
	launch.PID = os.Getpid()
	if launch.Directory == "" {
		if cwd, err := os.Getwd(); err == nil {
			launch.Directory = cwd
		}
	}
	if launch.Name == "" && launch.Directory != "" {
		launch.Name = filepath.Base(launch.Directory)
	}

	response, err := control.Send(cfg.Agent.Socket, launch)
	if err != nil {
		return err
	}
	if !response.OK {
		if response.Unavailable {
			// Machine-readable, because the caller is a program: it needs the moment to
			// retry at, not a sentence to parse.
			refusal, _ := json.Marshal(map[string]string{
				"error": response.Error, "retryAfter": response.RetryAfter,
			})
			fmt.Fprintln(os.Stderr, string(refusal))
			return &unavailable{message: response.Error}
		}
		return fmt.Errorf("%s", response.Error)
	}
	info := response.Session
	if info == nil {
		return fmt.Errorf("the agent started no session and gave no reason")
	}
	if err := confirmGroup(launch.Group, info); err != nil {
		_, _ = control.Send(cfg.Agent.Socket,
			control.Request{Op: control.OpEndSession, SessionID: info.SessionID})
		return err
	}

	fmt.Fprintf(os.Stderr, "ccmux: %s · %s · port %d\n", info.AccountLabel,
		modelOrAny(info.Model), info.Port)
	if info.Warning != "" {
		fmt.Fprintf(os.Stderr, "ccmux: warning — %s\n", info.Warning)
	}

	binary, err := claudeBinary(cfg.Agent.ClaudeBin)
	if err != nil {
		return err
	}
	environment := append(os.Environ(),
		"CLAUDE_SECURESTORAGE_CONFIG_DIR="+info.NamespaceDir,
		"ANTHROPIC_BASE_URL=http://127.0.0.1:"+strconv.Itoa(info.Port),
		// Keeps Claude Code's first-party behaviour against a loopback base URL.
		"_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1",
		"CCMUX_SESSION_ID="+info.SessionID,
	)
	return syscall.Exec(binary, append([]string{binary}, claudeArgs...), environment)
}

// confirmGroup refuses a session started by an agent that ignored --group, which is what
// one predating groups does: it would bill the run to accounts outside the group.
func confirmGroup(asked string, info *control.SessionInfo) error {
	if asked == "" || info.Group != "" {
		return nil
	}
	return fmt.Errorf("the agent did not apply --group %s, so it is older than this "+
		"ccmux; upgrade it and restart ccmux-agent", asked)
}

func modelOrAny(model string) string {
	if model == "" {
		return "any model"
	}
	return model
}

// withModel puts --model in front of the child's own arguments.
//
// The flag has to reach both: the agent ranks accounts on the model's weekly window, and
// an account picked against a window the request never consumes is the wrong account.
// Prepended rather than appended so a --model the caller passed after `--` still wins.
func withModel(model string, args []string) []string {
	if model == "" {
		return args
	}
	return append([]string{"--model", model}, args...)
}

// splitRunArgs takes the flags this shim owns and leaves everything else for claude, so
// `ccmux run -p "…"` works without a terminator.
func splitRunArgs(args []string) (control.Request, []string, error) {
	request := control.Request{Op: control.OpNewSession}
	var forwarded []string
	for i := 0; i < len(args); i++ {
		if args[i] == "--" {
			forwarded = append(forwarded, args[i+1:]...)
			return request, forwarded, nil
		}
		name, inline, hasInline := strings.Cut(args[i], "=")
		var into *string
		switch name {
		case "--model":
			into = &request.Model
		case "--account":
			into = &request.AccountID
		case "--name":
			into = &request.Name
		case "--group":
			into = &request.Group
		default:
			forwarded = append(forwarded, args[i])
			continue
		}
		if hasInline {
			*into = inline
			continue
		}
		i++
		if i >= len(args) {
			return request, nil, fmt.Errorf("%s needs a value", name)
		}
		*into = args[i]
	}
	return request, forwarded, nil
}

// claudeBinary resolves the executable, skipping this one so a symlink named `claude`
// pointing here cannot make the shim recurse.
func claudeBinary(configured string) (string, error) {
	if configured != "" {
		if err := executable(configured); err != nil {
			return "", fmt.Errorf("claude_bin %s: %w", configured, err)
		}
		return configured, nil
	}
	mine, _ := os.Executable()
	mine, _ = filepath.EvalSymlinks(mine)
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, "claude")
		if executable(candidate) != nil {
			continue
		}
		if resolved, err := filepath.EvalSymlinks(candidate); err == nil && resolved == mine {
			continue
		}
		return candidate, nil
	}
	if found, err := exec.LookPath("claude"); err == nil {
		return found, nil
	}
	return "", fmt.Errorf("could not find claude on PATH — set agent.claude_bin")
}

func executable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() || info.Mode()&0o111 == 0 {
		return fmt.Errorf("not executable")
	}
	return nil
}
