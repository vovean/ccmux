// Package config assembles the agent's settings from a YAML file, the environment and
// the command line, in that order of increasing precedence.
package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/goccy/go-yaml"
)

// DefaultPath is where the systemd unit looks unless --config says otherwise.
const DefaultPath = "/etc/ccmux/agent.yaml"

// CredentialName is the systemd LoadCredential= name a password may arrive under.
const CredentialName = "ccmux-password"

type Server struct {
	URL          string `yaml:"url"`
	Username     string `yaml:"username"`
	Password     string `yaml:"password"`
	PasswordFile string `yaml:"password_file"`
	// SHA-256 of the server certificate's leaf DER, hex. ccmuxd serves a self-signed
	// certificate, so this is the whole of the trust decision.
	Pin string `yaml:"pin"`
	// Plain HTTP, no pin. Tests and a TLS-terminating front end only: basic auth over
	// cleartext hands over the credential and every access token with it.
	Insecure bool `yaml:"insecure"`
}

type Agent struct {
	// How this box is named in the fleet. Defaults to the hostname.
	Label    string `yaml:"label"`
	StateDir string `yaml:"state_dir"`
	Socket   string `yaml:"socket"`
	Upstream string `yaml:"upstream"`
	// Absolute path to the claude executable. Empty resolves it on PATH at launch.
	ClaudeBin string `yaml:"claude_bin"`
	// Report sessions and usage to ccmuxd so this box appears on the Mac's pages.
	// A pointer so an explicit `false` in the file is not mistaken for absent.
	ReportFleet *bool `yaml:"report_fleet"`
	// Inclusive proxy port band, kept off the ephemeral range: a port is baked into a
	// running session's ANTHROPIC_BASE_URL and has to be rebindable after a restart.
	PortFirst int `yaml:"port_first"`
	PortLast  int `yaml:"port_last"`
}

type Config struct {
	Server Server `yaml:"server"`
	Agent  Agent  `yaml:"agent"`

	// Where the settings were read from, so an inline password can be refused on a
	// world-readable file.
	Path string `yaml:"-"`

	// Which source last set each of the two password settings. The password obeys the
	// same file < environment < flags precedence as everything else, which needs the
	// origin: two different fields can hold a password, and the newer one has to win
	// regardless of which field it landed in.
	passwordFrom     source
	passwordFileFrom source
}

type source int

const (
	sourceNone source = iota
	sourceFile
	sourceEnv
	sourceFlag
)

func Defaults() Config {
	report := true
	return Config{
		Server: Server{Username: "ccmux"},
		Agent: Agent{
			StateDir:    "/var/lib/ccmux",
			Socket:      "/run/ccmux/control.sock",
			Upstream:    "https://api.anthropic.com",
			ReportFleet: &report,
			PortFirst:   18000,
			PortLast:    18999,
		},
	}
}

func (c Config) Reports() bool { return c.Agent.ReportFleet == nil || *c.Agent.ReportFleet }

func (c Config) SessionsFile() string  { return filepath.Join(c.Agent.StateDir, "sessions.json") }
func (c Config) MachineFile() string   { return filepath.Join(c.Agent.StateDir, "machine.json") }
func (c Config) SpoolFile() string     { return filepath.Join(c.Agent.StateDir, "usage-spool.json") }
func (c Config) NamespaceRoot() string { return filepath.Join(c.Agent.StateDir, "ns") }

func (c Config) Namespace(sessionID string) string {
	return filepath.Join(c.NamespaceRoot(), sessionID)
}

const Usage = `ccmux — run Claude Code on a pool of subscriptions.

  ccmux agent [flags]               the daemon; systemd runs this
  ccmux run [flags] [-- claude-args]   start a session and exec claude
  ccmux status                      accounts, usage and live sessions
  ccmux assign <session> <account>  move a running session to another account
  ccmux end <session>               end a session the agent still believes is live
  ccmux version

Settings come from the YAML file, then the environment, then these flags:
  --config PATH      settings file (default ` + DefaultPath + `)
  --url URL          ccmuxd base URL
  --username NAME    basic-auth user
  --password-file F  file holding the basic-auth password, mode 0600
  --pin HEX          sha256 of ccmuxd's leaf certificate
  --label NAME       how this box is named in the fleet
  --state-dir PATH   sessions, namespaces and the usage spool
  --socket PATH      control socket
  --upstream URL     inference endpoint
  --claude-bin PATH  the claude executable
  --insecure         plain HTTP to ccmuxd, no pin — tests only
  --no-report        do not report sessions or usage to ccmuxd
`

// Load assembles the configuration and returns the arguments it did not consume, in
// order, with a bare "--" dropped. Unknown arguments are returned rather than refused:
// `ccmux run` forwards them to claude, and every other subcommand refuses a leftover
// itself, so a typo is never silently ignored.
func Load(args []string, env func(string) string) (Config, []string, error) {
	path, args, err := extractConfig(args, env)
	if err != nil {
		return Config{}, nil, err
	}
	config := Defaults()
	if err := applyFile(&config, path, path != ""); err != nil {
		return Config{}, nil, err
	}
	applyEnv(&config, env)
	rest, err := applyFlags(&config, args)
	if err != nil {
		return Config{}, nil, err
	}
	return config, rest, nil
}

// The file is read before anything else, so --config and CCMUX_CONFIG are pulled out of
// the argument list first. An explicit path that does not exist is an error; the default
// one simply not being there is not.
func extractConfig(args []string, env func(string) string) (string, []string, error) {
	kept := make([]string, 0, len(args))
	path := env("CCMUX_CONFIG")
	for i := 0; i < len(args); i++ {
		if args[i] == "--" {
			// Everything past here belongs to the child, this flag included.
			kept = append(kept, args[i:]...)
			break
		}
		if args[i] == "--config" {
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--config needs a value")
			}
			path = args[i+1]
			i++
			continue
		}
		if after, ok := strings.CutPrefix(args[i], "--config="); ok {
			path = after
			continue
		}
		kept = append(kept, args[i])
	}
	if path == "" {
		if _, err := os.Stat(DefaultPath); err == nil {
			return DefaultPath, kept, nil
		}
	}
	return path, kept, nil
}

func applyFile(config *Config, path string, required bool) error {
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) && !required {
			return nil
		}
		return fmt.Errorf("could not read %s: %w", path, err)
	}
	// Strict: a misspelled key in a settings file is a setting that silently does not
	// apply, which on this one would mean running against the wrong server.
	if err := yaml.UnmarshalWithOptions(data, config, yaml.Strict()); err != nil {
		// Never %w the raw error: goccy prints the offending line and its neighbours,
		// which for a file holding `password:` puts the one credential that draws a
		// token for every account into the journal.
		return fmt.Errorf("could not parse %s: %s", path,
			yaml.FormatError(err, false, false))
	}
	config.Path = path
	if config.Server.Password != "" {
		config.passwordFrom = sourceFile
	}
	if config.Server.PasswordFile != "" {
		config.passwordFileFrom = sourceFile
	}
	return nil
}

func applyEnv(config *Config, env func(string) string) {
	str := func(name string, into *string) {
		if v := env(name); v != "" {
			*into = v
		}
	}
	str("CCMUX_URL", &config.Server.URL)
	str("CCMUX_USERNAME", &config.Server.Username)
	if v := env("CCMUX_PASSWORD"); v != "" {
		config.Server.Password, config.passwordFrom = v, sourceEnv
	}
	if v := env("CCMUX_PASSWORD_FILE"); v != "" {
		config.Server.PasswordFile, config.passwordFileFrom = v, sourceEnv
	}
	str("CCMUX_PIN", &config.Server.Pin)
	str("CCMUX_LABEL", &config.Agent.Label)
	str("CCMUX_STATE_DIR", &config.Agent.StateDir)
	str("CCMUX_SOCKET", &config.Agent.Socket)
	str("CCMUX_UPSTREAM", &config.Agent.Upstream)
	str("CCMUX_CLAUDE_BIN", &config.Agent.ClaudeBin)
	if v := env("CCMUX_INSECURE"); v == "1" || strings.EqualFold(v, "true") {
		config.Server.Insecure = true
	}
	if v := env("CCMUX_REPORT_FLEET"); v != "" {
		report := v == "1" || strings.EqualFold(v, "true")
		config.Agent.ReportFleet = &report
	}
}

func applyFlags(config *Config, args []string) ([]string, error) {
	rest := make([]string, 0, len(args))
	value := func(i *int, inline string, hasInline bool) (string, error) {
		if hasInline {
			return inline, nil
		}
		*i++
		if *i >= len(args) {
			return "", fmt.Errorf("%s needs a value", args[*i-1])
		}
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			// The terminator itself is kept, not dropped: the subcommand that receives
			// these has its own flags to separate from the child's, and without it every
			// argument past here is parsed a second time.
			rest = append(rest, args[i:]...)
			return rest, nil
		}
		// `--label=` is an inline value that happens to be empty, not a flag whose value
		// is the next argument — reading the next one there swallows whatever followed.
		name, inline, hasInline := strings.Cut(arg, "=")
		var into *string
		switch name {
		case "--url":
			into = &config.Server.URL
		case "--username":
			into = &config.Server.Username
		case "--password-file":
			into = &config.Server.PasswordFile
			config.passwordFileFrom = sourceFlag
		case "--pin":
			into = &config.Server.Pin
		case "--label":
			into = &config.Agent.Label
		case "--state-dir":
			into = &config.Agent.StateDir
		case "--socket":
			into = &config.Agent.Socket
		case "--upstream":
			into = &config.Agent.Upstream
		case "--claude-bin":
			into = &config.Agent.ClaudeBin
		case "--insecure":
			config.Server.Insecure = true
			continue
		case "--no-report":
			report := false
			config.Agent.ReportFleet = &report
			continue
		default:
			rest = append(rest, arg)
			continue
		}
		v, err := value(&i, inline, hasInline)
		if err != nil {
			return nil, err
		}
		*into = v
	}
	return rest, nil
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Validate checks what can be checked without touching the network.
func (c Config) Validate() error {
	if c.Server.URL == "" {
		return fmt.Errorf("no server url: set server.url, CCMUX_URL or --url")
	}
	parsed, err := url.Parse(c.Server.URL)
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("server url %q is not a url", c.Server.URL)
	}
	switch {
	case c.Server.Insecure:
		// Deliberately permissive: --insecure is how the tests and a TLS-terminating
		// front end reach it, and both of those speak plain HTTP.
	case parsed.Scheme != "https":
		return fmt.Errorf("server url must be https (or pass --insecure)")
	case !hex64.MatchString(strings.ToLower(c.Server.Pin)):
		return fmt.Errorf("pin must be 64 hex characters — ccmuxd is self-signed, so " +
			"the pin is the whole of the trust decision")
	}
	if c.Server.Username == "" {
		return fmt.Errorf("no server username")
	}
	if c.Agent.PortFirst < 1024 || c.Agent.PortLast > 65535 ||
		c.Agent.PortFirst > c.Agent.PortLast {
		return fmt.Errorf("port band %d-%d is not usable",
			c.Agent.PortFirst, c.Agent.PortLast)
	}
	if c.Agent.StateDir == "" {
		return fmt.Errorf("no state directory")
	}
	return nil
}

// Password resolves the basic-auth password from whichever source holds it.
//
// A file the group or anyone else can read is refused rather than used: this one
// password draws an access token for every account on the server.
func (c Config) Password(env func(string) string) (string, error) {
	// At the same level the file wins: naming a file is the more deliberate of the two,
	// and it is the one an operator rotates without editing anything.
	if c.Server.PasswordFile != "" && c.passwordFileFrom >= c.passwordFrom {
		return readSecret(c.Server.PasswordFile)
	}
	if c.Server.Password != "" {
		// Only when the password actually came out of the settings file: a 0644 file
		// holding no password is nobody's problem, and refusing to start over it names
		// the wrong cause.
		if c.passwordFrom == sourceFile && c.Path != "" {
			if err := checkMode(c.Path); err != nil {
				return "", err
			}
		}
		return c.Server.Password, nil
	}
	// systemd LoadCredential=: the unit names a file, systemd copies it into a private
	// directory owned by this service and points us at it.
	if dir := env("CREDENTIALS_DIRECTORY"); dir != "" {
		path := filepath.Join(dir, CredentialName)
		if _, err := os.Stat(path); err == nil {
			// Not mode-checked: systemd owns this directory and makes it 0400 itself.
			data, err := os.ReadFile(path)
			if err != nil {
				return "", fmt.Errorf("could not read %s: %w", path, err)
			}
			return strings.TrimSpace(string(data)), nil
		}
	}
	return "", fmt.Errorf("no server password: set server.password_file, " +
		"CCMUX_PASSWORD, or systemd LoadCredential=" + CredentialName)
}

func readSecret(path string) (string, error) {
	if err := checkMode(path); err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("could not read %s: %w", path, err)
	}
	secret := strings.TrimSpace(string(data))
	if secret == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return secret, nil
}

func checkMode(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("could not read %s: %w", path, err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("%s is mode %04o and holds a password — chmod 600 it", path, perm)
	}
	return nil
}
