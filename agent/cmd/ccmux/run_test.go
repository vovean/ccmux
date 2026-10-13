package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"ccmuxagent/internal/agent"
	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
)

// The whole argument path, as an application actually invokes it: config.Load first, then
// the shim's own split. Getting the terminator wrong here runs claude with a prompt the
// caller did not write.
func argv(t *testing.T, args ...string) (string, []string) {
	t.Helper()
	_, rest, err := config.Load(args, func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	launch, forwarded, err := splitRunArgs(rest)
	if err != nil {
		t.Fatal(err)
	}
	return launch.Model, withModel(launch.Model, forwarded)
}

func TestArgumentsReachClaudeExactlyAsWritten(t *testing.T) {
	for _, tc := range []struct {
		name      string
		args      []string
		wantModel string
		wantArgv  []string
	}{
		{
			name:     "the documented form",
			args:     []string{"--", "-p", "summarise this"},
			wantArgv: []string{"-p", "summarise this"},
		},
		{
			name:      "the shim's flags before the terminator",
			args:      []string{"--model", "claude-opus-5", "--", "-p", "hi"},
			wantModel: "claude-opus-5",
			// The model reaches claude too, or the account was ranked on a window the
			// request will never consume.
			wantArgv: []string{"--model", "claude-opus-5", "-p", "hi"},
		},
		{
			name: "a model the caller passes after the terminator wins",
			args: []string{"--model", "claude-opus-5", "--", "-p", "hi",
				"--model", "claude-sonnet-5"},
			wantModel: "claude-opus-5",
			wantArgv: []string{"--model", "claude-opus-5", "-p", "hi",
				"--model", "claude-sonnet-5"},
		},
		{
			name:     "no terminator at all",
			args:     []string{"-p", "hi"},
			wantArgv: []string{"-p", "hi"},
		},
		{
			// Past the terminator nothing is the shim's, however much it looks like it.
			name:     "the shim's own flags past the terminator belong to claude",
			args:     []string{"--", "-p", "hi", "--name", "not-mine"},
			wantArgv: []string{"-p", "hi", "--name", "not-mine"},
		},
		{
			name:     "an agent flag past the terminator is not consumed either",
			args:     []string{"--", "-p", "hi", "--url", "http://not-mine"},
			wantArgv: []string{"-p", "hi", "--url", "http://not-mine"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, got := argv(t, tc.args...)
			if model != tc.wantModel {
				t.Errorf("model = %q, want %q", model, tc.wantModel)
			}
			if strings.Join(got, "\x00") != strings.Join(tc.wantArgv, "\x00") {
				t.Errorf("argv = %q, want %q", got, tc.wantArgv)
			}
		})
	}
}

func TestTheGroupFlagIsTheShimsNotClaudes(t *testing.T) {
	for _, tc := range []struct {
		name      string
		args      []string
		wantGroup string
		wantArgv  []string
	}{
		{name: "before the terminator", args: []string{"--group", "League", "--", "-p", "hi"},
			wantGroup: "League", wantArgv: []string{"-p", "hi"}},
		{name: "inline", args: []string{"--group=League", "-p", "hi"},
			wantGroup: "League", wantArgv: []string{"-p", "hi"}},
		{name: "past the terminator", args: []string{"--", "-p", "hi", "--group", "x"},
			wantArgv: []string{"-p", "hi", "--group", "x"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, rest, err := config.Load(tc.args, func(string) string { return "" })
			if err != nil {
				t.Fatal(err)
			}
			launch, forwarded, err := splitRunArgs(rest)
			if err != nil {
				t.Fatal(err)
			}
			if launch.Group != tc.wantGroup {
				t.Errorf("group = %q, want %q", launch.Group, tc.wantGroup)
			}
			if strings.Join(forwarded, "\x00") != strings.Join(tc.wantArgv, "\x00") {
				t.Errorf("argv = %q, want %q", forwarded, tc.wantArgv)
			}
		})
	}
}

// Stands in for the daemon. `confirms` is false for one that predates groups, which
// starts the session and drops the field without a word.
type standInAgent struct {
	confirms bool
	mu       sync.Mutex
	ended    []string
}

func (s *standInAgent) Handle(_ context.Context, request control.Request) control.Response {
	switch request.Op {
	case control.OpNewSession:
		info := &control.SessionInfo{SessionID: "s1", NamespaceDir: "/nowhere", Port: 18000,
			AccountLabel: "Work"}
		if s.confirms {
			info.Group = request.Group
		}
		return control.Response{OK: true, Session: info}
	case control.OpEndSession:
		s.mu.Lock()
		s.ended = append(s.ended, request.SessionID)
		s.mu.Unlock()
		return control.Response{OK: true}
	}
	return control.Response{Error: "unknown request " + request.Op}
}

// runAgainst runs the shim in-process against a stand-in daemon. claude_bin names nothing,
// so a run the shim lets through stops there instead of exec'ing over the test.
func runAgainst(t *testing.T, daemon *standInAgent, args ...string) error {
	t.Helper()
	dir := shortTempDir(t)
	socket := filepath.Join(dir, "run", "c.sock")
	server, err := control.Listen(socket, daemon, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go server.Serve(ctx)
	t.Cleanup(func() { cancel(); _ = server.Close() })

	settings := filepath.Join(dir, "agent.yaml")
	if err := os.WriteFile(settings, []byte("agent:\n  report_fleet: false\n"),
		0o600); err != nil {
		t.Fatal(err)
	}
	return runShim(append([]string{"--config", settings, "--socket", socket,
		"--claude-bin", filepath.Join(dir, "no-claude")}, args...))
}

// An agent too old to know --group would bill the run to accounts outside the group.
func TestARunRefusesAnAgentThatIgnoredItsGroup(t *testing.T) {
	daemon := &standInAgent{}
	err := runAgainst(t, daemon, "--group", "League", "--", "-p", "hi")
	if err == nil || !strings.Contains(err.Error(), "did not apply --group League") {
		t.Fatalf("got %v", err)
	}
	if code := exitCode(err); code != 1 {
		t.Errorf("exit %d, want 1: waiting will not upgrade the agent", code)
	}
	daemon.mu.Lock()
	defer daemon.mu.Unlock()
	if len(daemon.ended) != 1 || daemon.ended[0] != "s1" {
		t.Errorf("the session the old agent started was not ended: %q", daemon.ended)
	}
}

func TestARunGoesAheadWhenTheAgentConfirmsItsGroup(t *testing.T) {
	for _, tc := range []struct {
		name   string
		daemon *standInAgent
		args   []string
	}{
		{"a confirmed group", &standInAgent{confirms: true}, []string{"--group", "League"}},
		{"no group asked of an old agent", &standInAgent{}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := runAgainst(t, tc.daemon, append(tc.args, "--", "-p", "hi")...)
			// Past the check, the run stops only at the missing claude.
			if err == nil || !strings.Contains(err.Error(), "claude_bin") {
				t.Fatalf("got %v", err)
			}
			tc.daemon.mu.Lock()
			defer tc.daemon.mu.Unlock()
			if len(tc.daemon.ended) != 0 {
				t.Errorf("ended %q", tc.daemon.ended)
			}
		})
	}
}

func TestStatusShowsTheGroupsAndWhyAnAccountIsNotChosen(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status agent.Status
		want   []string
	}{
		{
			name: "a box limited to a group",
			status: agent.Status{MachineLabel: "box", Group: "League",
				Accounts: []agent.AccountStatus{
					{ID: "a", Label: "a", Groups: []string{"League", "Fast"}},
					{ID: "b", Label: "b", Groups: []string{"Fast"},
						NotAutomatic: "not in group League"},
					{ID: "c", Label: "c", NotAutomatic: "out of rotation",
						Unusable: "excluded by exclude_accounts (\"c\")"},
				}},
			want: []string{"group: League\n", "groups: League, Fast\n", "group: Fast\n",
				"not used automatically: not in group League\n",
				"not used: excluded by exclude_accounts (\"c\")\n"},
		},
		{
			name:   "a box with no group",
			status: agent.Status{MachineLabel: "box"},
			want:   []string{"group: ungrouped accounts only\n"},
		},
		{
			name: "a group that cannot be resolved",
			status: agent.Status{MachineLabel: "box", Group: "Leauge",
				GroupError: `no group "Leauge" on the server`},
			want: []string{`group: Leauge — runs without --group are refused: ` +
				`no group "Leauge" on the server`},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := printStatus(&out, tc.status); err != nil {
				t.Fatal(err)
			}
			for _, want := range tc.want {
				if !strings.Contains(out.String(), want) {
					t.Errorf("missing %q in:\n%s", want, out.String())
				}
			}
			// An account a pin cannot reach either says only why it is not used at all.
			if strings.Contains(out.String(), "out of rotation") {
				t.Errorf("an unusable account also listed a pin-only reason:\n%s", out.String())
			}
		})
	}
}
