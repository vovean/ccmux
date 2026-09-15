package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ccmuxagent/internal/agent"
	"ccmuxagent/internal/client"
	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
	"ccmuxd/wire"
)

// The whole chain, with only Anthropic and Claude Code faked: a real agent, a real
// control socket, a real per-session proxy, and a real `ccmux run` that execs a stand-in
// for claude which reads the environment it was handed and calls its own base URL.
func TestARunReachesTheApiThroughTheProxy(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a binary")
	}
	upstream, seen := fakeAnthropic(t)
	server := fakeCcmuxd(t, map[string]string{"a": "tok-a"})
	dir := shortTempDir(t)

	binary := buildCCMux(t, dir)
	claude := fakeClaude(t, dir)
	socket := filepath.Join(dir, "c.sock")

	cfg := agentConfig(t, server, dir, socket, upstream.URL, claude)
	stop := startAgent(t, cfg)
	defer stop()

	out, err := exec.Command(binary, "run",
		"--config", writeConfigFile(t, dir, cfg, server),
		"--model", "claude-opus-5", "--", "-p", "hello").CombinedOutput()
	if err != nil {
		t.Fatalf("run failed: %v\n%s", err, out)
	}
	text := string(out)

	// The shim told the operator which account it took.
	if !strings.Contains(text, "ccmux: Work") {
		t.Errorf("no account line: %s", text)
	}
	// Claude Code's stand-in saw the four variables the Mac sets, and its namespace held
	// the credential the agent seeded.
	for _, want := range []string{
		"CLAUDE_SECURESTORAGE_CONFIG_DIR=" + filepath.Join(dir, "state", "ns"),
		"ANTHROPIC_BASE_URL=http://127.0.0.1:19",
		"_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1",
		"CCMUX_SESSION_ID=",
		"SEEDED_TOKEN=tok-a",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	// The stand-in sent a stale bearer token and a stray x-api-key. What reached the API
	// is the account's own credential, with the other scheme cleared — billing it to a
	// different account is exactly what leaving it would do.
	if got := seen.auth(); got != "Bearer tok-a" {
		t.Errorf("the API saw %q, so the credential was not replaced", got)
	}
	if seen.apiKey != "" {
		t.Errorf("a stray x-api-key reached the API: %q", seen.apiKey)
	}
	// And the headers Claude Code sets for itself came through untouched.
	if seen.beta != "oauth-2025-04-20" {
		t.Errorf("anthropic-beta = %q", seen.beta)
	}
	if !strings.Contains(text, "UPSTREAM-OK") {
		t.Errorf("the call did not reach the API: %s", text)
	}
}

// A refusal an application can queue on rather than a failure it has to interpret.
func TestARunWithNothingFreeExitsSeventyFive(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a binary")
	}
	upstream, _ := fakeAnthropic(t)
	server := fakeCcmuxd(t, map[string]string{"a": "tok-a"})
	server.spend("a", time.Now().Add(3*time.Hour))
	dir := shortTempDir(t)

	binary := buildCCMux(t, dir)
	claude := fakeClaude(t, dir)
	socket := filepath.Join(dir, "c.sock")
	cfg := agentConfig(t, server, dir, socket, upstream.URL, claude)
	stop := startAgent(t, cfg)
	defer stop()

	cmd := exec.Command(binary, "run", "--config", writeConfigFile(t, dir, cfg, server),
		"--model", "claude-opus-5", "--", "-p", "hello")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("a run with nothing free succeeded: %s", out)
	}
	if code := cmd.ProcessState.ExitCode(); code != ExitUnavailable {
		t.Fatalf("exit %d, want %d (EX_TEMPFAIL)\n%s", code, ExitUnavailable, out)
	}
	// Machine-readable, because the caller is a program.
	var refusal struct {
		Error      string `json:"error"`
		RetryAfter string `json:"retryAfter"`
	}
	for _, line := range strings.Split(string(out), "\n") {
		if json.Unmarshal([]byte(line), &refusal) == nil && refusal.RetryAfter != "" {
			break
		}
	}
	if refusal.RetryAfter == "" {
		t.Fatalf("no machine-readable retry time: %s", out)
	}
	if _, err := time.Parse(time.RFC3339, refusal.RetryAfter); err != nil {
		t.Errorf("retryAfter %q: %v", refusal.RetryAfter, err)
	}
}

// --- the scaffolding ---

func shortTempDir(t *testing.T) string {
	t.Helper()
	// A unix socket path is bounded at ~104 bytes and the default temp name overflows it.
	dir, err := os.MkdirTemp("/tmp", "ccmuxe2e")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func buildCCMux(t *testing.T, dir string) string {
	t.Helper()
	binary := filepath.Join(dir, "ccmux")
	build := exec.Command("go", "build", "-o", binary, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building ccmux: %v\n%s", err, out)
	}
	return binary
}

// Stands in for claude: prints the environment it was handed, reads the credential the
// agent seeded for it, and calls its own base URL the way Claude Code would.
func fakeClaude(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "fake-claude")
	script := `#!/bin/sh
echo "ARGS=$*"
echo "CLAUDE_SECURESTORAGE_CONFIG_DIR=$CLAUDE_SECURESTORAGE_CONFIG_DIR"
echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
echo "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=$_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL"
echo "CCMUX_SESSION_ID=$CCMUX_SESSION_ID"
TOKEN=$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json")
echo "SEEDED_TOKEN=$TOKEN"
# Deliberately stale, and with an x-api-key beside it the way a shell exporting
# ANTHROPIC_API_KEY would produce: the proxy has to replace one and clear the other.
curl -s -H "Authorization: Bearer stale-token-claude-code-resolved-at-startup" \
  -H "x-api-key: sk-from-the-shell" -H "anthropic-beta: oauth-2025-04-20" \
  -d '{"model":"claude-opus-5","messages":[]}' "$ANTHROPIC_BASE_URL/v1/messages?beta=true"
echo
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

type apiRecorder struct {
	last   string
	apiKey string
	beta   string
}

func (r *apiRecorder) auth() string { return r.last }

func fakeAnthropic(t *testing.T) (*httptest.Server, *apiRecorder) {
	t.Helper()
	recorder := &apiRecorder{}
	server := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			recorder.last = r.Header.Get("Authorization")
			recorder.apiKey = r.Header.Get("x-api-key")
			recorder.beta = r.Header.Get("anthropic-beta")
			w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.42")
			_, _ = w.Write([]byte(`{"id":"msg_1","content":[{"type":"text",` +
				`"text":"UPSTREAM-OK"}],"usage":{"input_tokens":7,"output_tokens":3}}`))
		}))
	t.Cleanup(server.Close)
	return server, recorder
}

type ccmuxdStub struct {
	*httptest.Server
	windows map[string][]wire.UsageWindow
}

func (s *ccmuxdStub) spend(accountID string, resetsAt time.Time) {
	s.windows[accountID] = []wire.UsageWindow{{Kind: wire.WindowWeeklyAll, Label: "Weekly",
		Percent: 100, ResetsAt: &wire.Time{Time: resetsAt}}}
}

func fakeCcmuxd(t *testing.T, tokens map[string]string) *ccmuxdStub {
	t.Helper()
	stub := &ccmuxdStub{windows: map[string][]wire.UsageWindow{}}
	for id := range tokens {
		stub.windows[id] = []wire.UsageWindow{
			{Kind: wire.WindowWeeklyAll, Label: "Weekly", Percent: 20}}
	}
	write := func(w http.ResponseWriter, payload any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(payload)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.HealthResponse{APIVersion: wire.APIVersion,
			Features: []string{"sessions", "usage-series"}})
	})
	mux.HandleFunc("GET /v1/accounts", func(w http.ResponseWriter, _ *http.Request) {
		accounts := make([]wire.RemoteAccount, 0, len(tokens))
		for id := range tokens {
			accounts = append(accounts, wire.RemoteAccount{ID: id, Label: "Work",
				Kind: wire.KindSubscription, Health: wire.HealthOK})
		}
		write(w, wire.AccountListResponse{APIVersion: wire.APIVersion, Accounts: accounts})
	})
	mux.HandleFunc("GET /v1/accounts/{id}/usage", func(w http.ResponseWriter, r *http.Request) {
		write(w, wire.RemoteUsage{AccountID: r.PathValue("id"),
			Windows: stub.windows[r.PathValue("id")], AgeSeconds: 5})
	})
	mux.HandleFunc("GET /v1/accounts/{id}/token", func(w http.ResponseWriter, r *http.Request) {
		token, ok := tokens[r.PathValue("id")]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			write(w, wire.ServerErrorResponse{Error: wire.ServerErrorDetail{Message: "none"}})
			return
		}
		life := 3600.0
		write(w, wire.TokenGrant{AccountID: r.PathValue("id"), Kind: wire.KindSubscription,
			AccessToken: &token, ExpiresIn: &life, SubscriptionType: wire.Ptr("team")})
	})
	mux.HandleFunc("POST /v1/machines/{id}/sessions", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.SessionsResponse{APIVersion: wire.APIVersion})
	})
	mux.HandleFunc("POST /v1/machines/{id}/usage", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.UsageIngestResponse{APIVersion: wire.APIVersion})
	})
	stub.Server = httptest.NewTLSServer(mux)
	t.Cleanup(stub.Close)
	return stub
}

func agentConfig(t *testing.T, server *ccmuxdStub, dir, socket, upstream,
	claude string) config.Config {
	t.Helper()
	sum := sha256.Sum256(server.Certificate().Raw)
	cfg := config.Defaults()
	cfg.Server.URL = server.URL
	cfg.Server.Pin = hex.EncodeToString(sum[:])
	cfg.Server.Password = "hunter2"
	cfg.Agent.StateDir = filepath.Join(dir, "state")
	cfg.Agent.Socket = socket
	cfg.Agent.Upstream = upstream
	cfg.Agent.ClaudeBin = claude
	cfg.Agent.Label = "e2e"
	cfg.Agent.PortFirst, cfg.Agent.PortLast = 19900, 19989
	report := false
	cfg.Agent.ReportFleet = &report
	return cfg
}

// The `run` shim is a separate process, so it reads the same settings from a file.
func writeConfigFile(t *testing.T, dir string, cfg config.Config, server *ccmuxdStub) string {
	t.Helper()
	path := filepath.Join(dir, "agent.yaml")
	body := fmt.Sprintf(`server:
  url: %s
  password: hunter2
  pin: %s
agent:
  state_dir: %s
  socket: %s
  upstream: %s
  claude_bin: %s
  port_first: 19900
  port_last: 19989
  report_fleet: false
`, cfg.Server.URL, cfg.Server.Pin, cfg.Agent.StateDir, cfg.Agent.Socket,
		cfg.Agent.Upstream, cfg.Agent.ClaudeBin)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func startAgent(t *testing.T, cfg config.Config) func() {
	t.Helper()
	api, err := client.New(cfg, "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := agent.New(cfg, api, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err := daemon.Start(ctx); err != nil {
		cancel()
		t.Fatal(err)
	}
	socket, err := control.Listen(cfg.Agent.Socket, daemon, func(string, ...any) {})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	go socket.Serve(ctx)
	go daemon.Run(ctx)
	return func() { cancel(); _ = socket.Close() }
}
