package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envFrom(pairs map[string]string) func(string) string {
	return func(name string) string { return pairs[name] }
}

func writeFile(t *testing.T, dir, name, body string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	// WriteFile honours umask, so the mode has to be set explicitly for the 0600 checks.
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

const sample = `
server:
  url: https://file.example:8443
  username: from-file
  pin: aa11
agent:
  label: from-file
  upstream: https://file.upstream
`

// The whole point of three sources is that the later one wins, one field at a time.
func TestPrecedenceIsFileThenEnvThenFlags(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "agent.yaml", sample, 0o600)

	config, rest, err := Load(
		[]string{"--config", path, "--label", "from-flag"},
		envFrom(map[string]string{
			"CCMUX_URL":      "https://env.example",
			"CCMUX_LABEL":    "from-env",
			"CCMUX_USERNAME": "",
		}))
	if err != nil {
		t.Fatal(err)
	}
	if len(rest) != 0 {
		t.Fatalf("unexpected leftovers %v", rest)
	}
	if config.Server.URL != "https://env.example" {
		t.Errorf("env should beat the file, got %q", config.Server.URL)
	}
	if config.Agent.Label != "from-flag" {
		t.Errorf("a flag should beat the env, got %q", config.Agent.Label)
	}
	// An empty environment variable is absent, not an instruction to blank the setting.
	if config.Server.Username != "from-file" {
		t.Errorf("empty env cleared a file value: %q", config.Server.Username)
	}
	// Untouched by anything later keeps the file's value; untouched by anything at all
	// keeps the default.
	if config.Agent.Upstream != "https://file.upstream" {
		t.Errorf("file value lost: %q", config.Agent.Upstream)
	}
	if config.Agent.StateDir != "/var/lib/ccmux" {
		t.Errorf("default lost: %q", config.Agent.StateDir)
	}
}

func TestUnknownArgumentsAreReturnedNotRefused(t *testing.T) {
	config, rest, err := Load(
		[]string{"--url", "https://x", "-p", "hello", "--", "--url", "not-mine"},
		envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if config.Server.URL != "https://x" {
		t.Fatalf("flag not applied: %q", config.Server.URL)
	}
	// Past `--` even a flag this package owns belongs to the child, and the terminator
	// survives so the next parser can tell where the child's arguments begin.
	want := []string{"-p", "hello", "--", "--url", "not-mine"}
	if len(rest) != len(want) {
		t.Fatalf("got %v, want %v", rest, want)
	}
	for i := range want {
		if rest[i] != want[i] {
			t.Fatalf("got %v, want %v", rest, want)
		}
	}
}

func TestAMisspelledKeyIsRefused(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "agent.yaml", "server:\n  ulr: https://typo\n", 0o600)
	if _, _, err := Load([]string{"--config", path}, envFrom(nil)); err == nil {
		t.Fatal("a misspelled key should be refused, not ignored")
	}
}

func TestAnExplicitConfigFileMustExist(t *testing.T) {
	if _, _, err := Load([]string{"--config", "/nope/agent.yaml"}, envFrom(nil)); err == nil {
		t.Fatal("an explicit --config that is not there should be an error")
	}
}

// This one password draws an access token for every account on the server.
func TestAReadablePasswordFileIsRefused(t *testing.T) {
	dir := t.TempDir()
	loose := writeFile(t, dir, "password", "hunter2\n", 0o644)
	config := Defaults()
	config.Server.PasswordFile = loose
	if _, err := config.Password(envFrom(nil)); err == nil {
		t.Fatal("a group-readable password file should be refused")
	}
	if err := os.Chmod(loose, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := config.Password(envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if got != "hunter2" {
		t.Errorf("got %q", got)
	}
}

func TestAnInlinePasswordIsRefusedOnAReadableFile(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "agent.yaml", "server:\n  password: hunter2\n", 0o644)
	config, _, err := Load([]string{"--config", path}, envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.Password(envFrom(nil)); err == nil {
		t.Fatal("an inline password in a readable file should be refused")
	}
}

func TestSystemdCredentialIsTheLastResort(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, CredentialName, "from-systemd\n", 0o400)
	config := Defaults()
	got, err := config.Password(envFrom(map[string]string{"CREDENTIALS_DIRECTORY": dir}))
	if err != nil {
		t.Fatal(err)
	}
	if got != "from-systemd" {
		t.Errorf("got %q", got)
	}
}

func TestValidate(t *testing.T) {
	pin := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for _, tc := range []struct {
		name    string
		mutate  func(*Config)
		wantErr bool
	}{
		{"https with a pin", func(c *Config) { c.Server.URL = "https://h:8443"; c.Server.Pin = pin }, false},
		{"https without a pin", func(c *Config) { c.Server.URL = "https://h:8443" }, true},
		{"a short pin", func(c *Config) { c.Server.URL = "https://h"; c.Server.Pin = "aa" }, true},
		{"plain http", func(c *Config) { c.Server.URL = "http://h:8443"; c.Server.Pin = pin }, true},
		{"plain http with --insecure", func(c *Config) { c.Server.URL = "http://h:8443"; c.Server.Insecure = true }, false},
		{"no url at all", func(c *Config) {}, true},
		{"an inverted port band", func(c *Config) {
			c.Server.URL = "https://h"
			c.Server.Pin = pin
			c.Agent.PortFirst, c.Agent.PortLast = 19000, 18000
		}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			config := Defaults()
			tc.mutate(&config)
			err := config.Validate()
			if tc.wantErr != (err != nil) {
				t.Fatalf("Validate() = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}

// goccy's error text quotes the offending line and its neighbours. On a file holding an
// inline password that is the one credential that draws an access token for every
// account on the server, and systemd puts the agent's stderr in the journal.
func TestAParseErrorNeverQuotesThePassword(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "agent.yaml",
		"server:\n  url: https://h\n  password: sup3rs3cr3t\n  ulr: typo\n", 0o600)
	_, _, err := Load([]string{"--config", path}, envFrom(nil))
	if err == nil {
		t.Fatal("a misspelled key should be refused")
	}
	if strings.Contains(err.Error(), "sup3rs3cr3t") {
		t.Fatalf("the password reached the error text: %s", err)
	}
	if !strings.Contains(err.Error(), "ulr") {
		t.Errorf("the reason was lost: %s", err)
	}
}

func TestTheEnvironmentBeatsAPasswordFileNamedInTheFile(t *testing.T) {
	dir := t.TempDir()
	stale := writeFile(t, dir, "old-password", "stale\n", 0o600)
	path := writeFile(t, dir, "agent.yaml",
		"server:\n  password_file: "+stale+"\n", 0o600)
	config, _, err := Load([]string{"--config", path}, envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	// With nothing newer, the file's own setting stands.
	if got, _ := config.Password(envFrom(nil)); got != "stale" {
		t.Fatalf("got %q", got)
	}

	rotated, _, err := Load([]string{"--config", path},
		envFrom(map[string]string{"CCMUX_PASSWORD": "fresh"}))
	if err != nil {
		t.Fatal(err)
	}
	got, err := rotated.Password(envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if got != "fresh" {
		t.Errorf("the environment did not beat the file: %q", got)
	}
}

// A settings file that holds no password is nobody's problem, whatever its mode.
func TestAReadableFileWithNoPasswordInItIsFine(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "agent.yaml", "server:\n  url: https://h\n", 0o644)
	config, _, err := Load([]string{"--config", path},
		envFrom(map[string]string{"CCMUX_PASSWORD": "from-env"}))
	if err != nil {
		t.Fatal(err)
	}
	got, err := config.Password(envFrom(nil))
	if err != nil {
		t.Fatalf("refused a password the file never held: %v", err)
	}
	if got != "from-env" {
		t.Errorf("got %q", got)
	}
}

func TestAnEmptyInlineValueDoesNotSwallowTheNextArgument(t *testing.T) {
	config, rest, err := Load([]string{"--label=", "--insecure"}, envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if config.Agent.Label != "" {
		t.Errorf("label = %q", config.Agent.Label)
	}
	if !config.Server.Insecure {
		t.Error("--insecure was swallowed as the label's value")
	}
	if len(rest) != 0 {
		t.Errorf("leftovers %v", rest)
	}
}

func TestConfigFlagsPastTheTerminatorBelongToTheChild(t *testing.T) {
	config, rest, err := Load(
		[]string{"--url", "https://mine", "--", "claude", "--config", "/home/u/cc.json"},
		envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if config.Server.URL != "https://mine" {
		t.Fatalf("url = %q", config.Server.URL)
	}
	want := []string{"--", "claude", "--config", "/home/u/cc.json"}
	if len(rest) != len(want) {
		t.Fatalf("got %v, want %v", rest, want)
	}
	for i := range want {
		if rest[i] != want[i] {
			t.Fatalf("got %v, want %v", rest, want)
		}
	}
}

func TestATrailingConfigWithNoValueIsRefused(t *testing.T) {
	if _, _, err := Load([]string{"--config"}, envFrom(nil)); err == nil {
		t.Fatal("a --config with nothing after it should say so, not reach the child")
	}
}

func TestExcludedAccountsComeFromTheFileOrTheEnvironment(t *testing.T) {
	path := writeFile(t, t.TempDir(), "agent.yaml",
		"agent:\n  exclude_accounts: [Emcd, 5570f35c-4975-4707-a1ef-735b70b49871]\n", 0o600)

	config, _, err := Load([]string{"--config", path}, envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(config.Agent.ExcludeAccounts, "|"); got !=
		"Emcd|5570f35c-4975-4707-a1ef-735b70b49871" {
		t.Errorf("from the file: %q", got)
	}

	// The environment replaces the list rather than adding to it, like every other setting.
	config, _, err = Load([]string{"--config", path},
		envFrom(map[string]string{"CCMUX_EXCLUDE_ACCOUNTS": " emcd2 , ,vv@amnezia.org "}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(config.Agent.ExcludeAccounts, "|"); got != "emcd2|vv@amnezia.org" {
		t.Errorf("from the environment: %q", got)
	}

	// Blanks and commas name nothing, and must not wipe the file's list.
	config, _, err = Load([]string{"--config", path},
		envFrom(map[string]string{"CCMUX_EXCLUDE_ACCOUNTS": " , "}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(config.Agent.ExcludeAccounts, "|"); got !=
		"Emcd|5570f35c-4975-4707-a1ef-735b70b49871" {
		t.Errorf("a blank environment value replaced the list: %q", got)
	}
}

// Daemon-only: `ccmux run` parses its own --group, which config.Load must hand on rather
// than take for the box's.
func TestTheGroupComesFromTheFileOrTheEnvironmentButNoFlag(t *testing.T) {
	path := writeFile(t, t.TempDir(), "agent.yaml", "agent:\n  group: League\n", 0o600)

	config, _, err := Load([]string{"--config", path}, envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if config.Agent.Group != "League" {
		t.Errorf("from the file: %q", config.Agent.Group)
	}

	config, rest, err := Load([]string{"--config", path, "--group", "Fast"},
		envFrom(map[string]string{"CCMUX_GROUP": "Build"}))
	if err != nil {
		t.Fatal(err)
	}
	if config.Agent.Group != "Build" {
		t.Errorf("the environment did not beat the file: %q", config.Agent.Group)
	}
	if strings.Join(rest, " ") != "--group Fast" {
		t.Errorf("--group was consumed as a setting: %q", rest)
	}
}
