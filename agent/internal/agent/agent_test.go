package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ccmuxagent/internal/client"
	"ccmuxagent/internal/config"
	"ccmuxagent/internal/control"
	"ccmuxd/wire"
)

var noon = time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)

// A fake ccmuxd serving the wire shapes the agent needs.
type fakeServer struct {
	accounts []wire.RemoteAccount
	groups   []wire.SubscriptionGroup
	usage    map[string][]wire.UsageWindow
	tokens   map[string]string
	features []string
	// The groups route answers 503 while this is set, as ccmuxd does when it cannot read
	// its groups file.
	groupsDown bool
	groupReads int
	// Requests for a token, per account, so a test can prove one was drawn once.
	draws map[string]int
	http  *httptest.Server
}

func newFakeServer(t *testing.T) *fakeServer {
	t.Helper()
	fake := &fakeServer{
		usage:    map[string][]wire.UsageWindow{},
		tokens:   map[string]string{},
		draws:    map[string]int{},
		features: []string{"sessions", "hooks", "usage-series", wire.FeatureGroups},
	}
	mux := http.NewServeMux()
	write := func(w http.ResponseWriter, payload any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(payload)
	}
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.HealthResponse{APIVersion: wire.APIVersion, Features: fake.features})
	})
	mux.HandleFunc("GET /v1/accounts", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.AccountListResponse{APIVersion: wire.APIVersion, Accounts: fake.accounts})
	})
	mux.HandleFunc("GET /v1/groups", func(w http.ResponseWriter, _ *http.Request) {
		fake.groupReads++
		if fake.groupsDown {
			w.WriteHeader(http.StatusServiceUnavailable)
			write(w, wire.ServerErrorResponse{
				Error: wire.ServerErrorDetail{Message: "groups.json could not be read"}})
			return
		}
		write(w, wire.GroupListResponse{APIVersion: wire.APIVersion, Groups: fake.groups})
	})
	mux.HandleFunc("GET /v1/accounts/{id}/usage", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		windows, ok := fake.usage[id]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			write(w, wire.ServerErrorResponse{Error: wire.ServerErrorDetail{Message: "none"}})
			return
		}
		write(w, wire.RemoteUsage{AccountID: id, Windows: windows, AgeSeconds: 12})
	})
	mux.HandleFunc("GET /v1/accounts/{id}/token", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		fake.draws[id]++
		token, ok := fake.tokens[id]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			write(w, wire.ServerErrorResponse{
				Error: wire.ServerErrorDetail{Message: "no usable credential for " + id}})
			return
		}
		life := 3600.0
		write(w, wire.TokenGrant{AccountID: id, Kind: wire.KindSubscription,
			AccessToken: &token, ExpiresIn: &life,
			SubscriptionType: wire.Ptr("team"), Scopes: []string{"user:inference"}})
	})
	mux.HandleFunc("POST /v1/machines/{id}/sessions", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.SessionsResponse{APIVersion: wire.APIVersion})
	})
	mux.HandleFunc("POST /v1/machines/{id}/usage", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.UsageIngestResponse{APIVersion: wire.APIVersion, Accepted: 0})
	})
	fake.http = httptest.NewTLSServer(mux)
	t.Cleanup(fake.http.Close)
	return fake
}

func (f *fakeServer) client(t *testing.T) (*client.Client, config.Config) {
	t.Helper()
	sum := sha256.Sum256(f.http.Certificate().Raw)
	cfg := config.Defaults()
	cfg.Server.URL = f.http.URL
	cfg.Server.Pin = hex.EncodeToString(sum[:])
	cfg.Agent.StateDir = t.TempDir()
	cfg.Agent.Label = "test-box"
	// Well clear of the 18000-18999 band a real agent uses.
	cfg.Agent.PortFirst, cfg.Agent.PortLast = 19800, 19899
	api, err := client.New(cfg, "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	return api, cfg
}

func window(kind wire.WindowKind, percent float64, model string) wire.UsageWindow {
	w := wire.UsageWindow{Kind: kind, Label: string(kind), Percent: percent}
	if model != "" {
		w.ModelName = wire.Ptr(model)
	}
	return w
}

func newAgent(t *testing.T, fake *fakeServer) *Agent {
	t.Helper()
	return newAgentWith(t, fake, nil)
}

func newAgentWith(t *testing.T, fake *fakeServer, adjust func(*config.Config)) *Agent {
	t.Helper()
	daemon, _ := newLoggedAgent(t, fake, adjust)
	return daemon
}

// newLoggedAgent is newAgentWith keeping what the agent logged.
func newLoggedAgent(t *testing.T, fake *fakeServer,
	adjust func(*config.Config)) (*Agent, *[]string) {
	t.Helper()
	api, cfg := fake.client(t)
	if adjust != nil {
		adjust(&cfg)
	}
	logged := &[]string{}
	daemon, err := New(cfg, api, func(format string, args ...any) {
		*logged = append(*logged, fmt.Sprintf(format, args...))
	})
	if err != nil {
		t.Fatal(err)
	}
	daemon.now = func() time.Time { return noon }
	if err := daemon.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(daemon.shutdown)
	return daemon, logged
}

// restart stops the agent the way systemd does and starts another on the same state, so
// its sessions are recovered from the file rather than carried over in memory.
func restart(t *testing.T, old *Agent) *Agent {
	t.Helper()
	old.shutdown()
	daemon, err := New(old.config, old.client, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	daemon.now = old.now
	if err := daemon.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(daemon.shutdown)
	return daemon
}

func TestALaunchTakesTheMostDrainedAccountThatCanServeTheModel(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "fresh", Label: "Fresh", Kind: wire.KindSubscription, Health: wire.HealthOK},
		{ID: "drained", Label: "Drained", Kind: wire.KindSubscription, Health: wire.HealthOK},
	}
	fake.usage["fresh"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 5, "")}
	fake.usage["drained"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 80, "")}
	fake.tokens["fresh"], fake.tokens["drained"] = "tok-fresh", "tok-drained"

	daemon := newAgent(t, fake)
	started, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "drained" {
		t.Fatalf("started on %q, want the most drained", started.AccountID)
	}
	if started.Port < 19800 || started.Port > 19899 {
		t.Errorf("port %d is outside the configured band", started.Port)
	}

	// The seeded credential is what Claude Code will authenticate as.
	data, err := os.ReadFile(filepath.Join(started.NamespaceDir, ".credentials.json"))
	if err != nil {
		t.Fatal(err)
	}
	var seeded struct {
		OAuth struct {
			AccessToken      string   `json:"accessToken"`
			RefreshToken     string   `json:"refreshToken"`
			ExpiresAt        int64    `json:"expiresAt"`
			SubscriptionType string   `json:"subscriptionType"`
			Scopes           []string `json:"scopes"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &seeded); err != nil {
		t.Fatal(err)
	}
	if seeded.OAuth.AccessToken != "tok-drained" {
		t.Errorf("seeded %q", seeded.OAuth.AccessToken)
	}
	// ccmuxd is the sole holder of every lineage; a box that could refresh could rotate
	// one behind the server's back.
	if seeded.OAuth.RefreshToken != "" {
		t.Error("a refresh token reached the box")
	}
	// A credential missing its plan reads as unentitled.
	if seeded.OAuth.SubscriptionType != "team" {
		t.Errorf("plan %q", seeded.OAuth.SubscriptionType)
	}
	if seeded.OAuth.ExpiresAt != noon.Add(time.Hour).UnixMilli() {
		t.Errorf("expiry %d", seeded.OAuth.ExpiresAt)
	}

	// The token lives here; nobody else on the box may read it.
	info, err := os.Stat(filepath.Join(started.NamespaceDir, ".credentials.json"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Errorf("credential file is mode %04o", perm)
	}
	dirInfo, err := os.Stat(started.NamespaceDir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := dirInfo.Mode().Perm(); perm&0o077 != 0 {
		t.Errorf("namespace directory is mode %04o", perm)
	}
}

// An application driving `claude -p` wants to hear "nothing is free until 14:00" as a
// refusal it can queue on, not as a failed run it has to interpret.
func TestALaunchWithNothingFreeIsRefusedWithAMoment(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "spent", Label: "Spent", Kind: wire.KindSubscription, Health: wire.HealthOK},
	}
	reset := wire.Time{Time: noon.Add(2 * time.Hour)}
	fake.usage["spent"] = []wire.UsageWindow{
		{Kind: wire.WindowWeeklyAll, Label: "Weekly", Percent: 100, ResetsAt: &reset}}
	fake.tokens["spent"] = "tok"

	daemon := newAgent(t, fake)
	_, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	var refusal *ErrNoAccount
	if err == nil {
		t.Fatal("a launch with nothing free was allowed")
	}
	if !asNoAccount(err, &refusal) {
		t.Fatalf("got %v, want ErrNoAccount", err)
	}
	if !refusal.At.Equal(noon.Add(2 * time.Hour)) {
		t.Errorf("retry at %v", refusal.At)
	}
	// And nothing was drawn or seeded for a run that never started.
	if fake.draws["spent"] != 0 {
		t.Error("a credential was drawn for a refused launch")
	}
}

func asNoAccount(err error, target **ErrNoAccount) bool {
	cast, ok := err.(*ErrNoAccount)
	if ok {
		*target = cast
	}
	return ok
}

// A rotation moves who serves the session; it must not move what the session *is* across
// an organisation boundary, because that changes which managed plugins Claude Code must
// load and blocks every model switch after it.
func TestOrganisationPinning(t *testing.T) {
	emcd, win := "org-emcd", "org-1win"
	for _, tc := range []struct {
		name    string
		reason  Reason
		seeded  *string
		target  *string
		reseeds bool
	}{
		{"a rotation inside one organisation", Rotation, &emcd, &emcd, true},
		{"a rotation across organisations", Rotation, &emcd, &win, false},
		{"a rotation onto an account with no organisation", Rotation, &emcd, nil, false},
		{"a rotation from an account with no organisation", Rotation, nil, &emcd, false},
		{"an explicit move across organisations", Explicit, &emcd, &win, true},
		{"an explicit move onto an api key", Explicit, &emcd, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := MayReseed(tc.reason, tc.seeded, tc.target); got != tc.reseeds {
				t.Errorf("got %v, want %v", got, tc.reseeds)
			}
		})
	}
	// Empty is the same as absent: two blanks matching must not read as two accounts
	// agreeing about anything.
	blank := ""
	if SameOrganisation(&blank, &blank) {
		t.Error("two blank organisations were treated as the same one")
	}
}

func TestARotationMovesWhoServesButNotWhatTheSessionIs(t *testing.T) {
	fake := newFakeServer(t)
	emcd, win := "org-emcd", "org-1win"
	fake.accounts = []wire.RemoteAccount{
		{ID: "a", Label: "A", Kind: wire.KindSubscription, Health: wire.HealthOK,
			OrganizationUUID: &emcd},
		{ID: "b", Label: "B", Kind: wire.KindSubscription, Health: wire.HealthOK,
			OrganizationUUID: &win},
	}
	fake.usage["a"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 80, "")}
	fake.usage["b"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 5, "")}
	fake.tokens["a"], fake.tokens["b"] = "tok-a", "tok-b"

	daemon := newAgent(t, fake)
	started, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "a" {
		t.Fatalf("started on %q", started.AccountID)
	}

	if err := daemon.Assign(context.Background(), started.SessionID, "b", Rotation); err != nil {
		t.Fatal(err)
	}
	daemon.mu.Lock()
	record := daemon.sessions[started.SessionID].record
	daemon.mu.Unlock()
	if record.AccountID != "b" {
		t.Errorf("serving account is %q", record.AccountID)
	}
	if record.SeededAccountID != "a" {
		t.Errorf("the identity crossed the boundary: seeded as %q", record.SeededAccountID)
	}
	// And the namespace still holds the account it launched on.
	data, _ := os.ReadFile(filepath.Join(started.NamespaceDir, ".credentials.json"))
	if !containsToken(data, "tok-a") {
		t.Errorf("the namespace was reseeded: %s", data)
	}

	// An explicit move takes the identity with it.
	if err := daemon.Assign(context.Background(), started.SessionID, "b", Explicit); err != nil {
		t.Fatal(err)
	}
	daemon.mu.Lock()
	record = daemon.sessions[started.SessionID].record
	daemon.mu.Unlock()
	if record.SeededAccountID != "b" {
		t.Errorf("an explicit move left the identity behind: %q", record.SeededAccountID)
	}
	data, _ = os.ReadFile(filepath.Join(started.NamespaceDir, ".credentials.json"))
	if !containsToken(data, "tok-b") {
		t.Errorf("the namespace was not reseeded: %s", data)
	}
}

func containsToken(data []byte, token string) bool {
	var seeded struct {
		OAuth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	return json.Unmarshal(data, &seeded) == nil && seeded.OAuth.AccessToken == token
}

// A dead run's namespace holds a live access token; it has to go with the session.
func TestReapingADeadRunClearsItsCredential(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "a", Label: "A", Kind: wire.KindSubscription, Health: wire.HealthOK}}
	fake.usage["a"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 10, "")}
	fake.tokens["a"] = "tok-a"

	daemon := newAgent(t, fake)
	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	// Pretend the run exited: pid 1 is alive but is not ours, so use an impossible one.
	daemon.mu.Lock()
	daemon.sessions[started.SessionID].record.PID = 0
	daemon.mu.Unlock()

	daemon.reap()
	if _, err := os.Stat(started.NamespaceDir); !os.IsNotExist(err) {
		t.Fatalf("the namespace outlived the run: %v", err)
	}
	daemon.mu.Lock()
	remaining := len(daemon.sessions)
	daemon.mu.Unlock()
	if remaining != 0 {
		t.Errorf("%d sessions left", remaining)
	}
}

// An account whose lineage is dead must not take a session down with it.
func TestALaunchOnAnAccountWithNoCredentialFails(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "a", Label: "A", Kind: wire.KindSubscription, Health: wire.HealthOK}}
	fake.usage["a"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 10, "")}
	// No token for it.

	daemon := newAgent(t, fake)
	if _, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()}); err == nil {
		t.Fatal("a session started with no credential")
	}
}

func TestAGrantIsDrawnOnceAndReused(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "a", Label: "A", Kind: wire.KindSubscription, Health: wire.HealthOK}}
	fake.usage["a"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 10, "")}
	fake.tokens["a"] = "tok-a"

	daemon := newAgent(t, fake)
	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if _, ok := daemon.Assignment(started.SessionID); !ok {
			t.Fatalf("assignment %d refused", i)
		}
	}
	if fake.draws["a"] != 1 {
		t.Errorf("drew %d tokens for one account", fake.draws["a"])
	}
}

func TestTheSessionsFileSurvivesARestart(t *testing.T) {
	store := NewStore(filepath.Join(t.TempDir(), "sessions.json"))
	if err := store.Save([]Session{{ID: "s1", PID: 42, Port: 18000, AccountID: "a",
		SeededAccountID: "b", StartedAt: noon}}); err != nil {
		t.Fatal(err)
	}
	back, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(back) != 1 || back[0].AccountID != "a" || back[0].SeededAccountID != "b" {
		t.Fatalf("got %+v", back)
	}
}

// A record written before the field existed must not decode to an empty identity, which
// would re-seed every live session on the next tick.
func TestASessionWrittenBeforeTheIdentityFieldKeepsItsAccount(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sessions.json")
	if err := os.WriteFile(path,
		[]byte(`[{"id":"s1","pid":42,"port":18000,"accountID":"a"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	back, err := NewStore(path).Load()
	if err != nil {
		t.Fatal(err)
	}
	if back[0].SeededAccountID != "a" {
		t.Errorf("seeded as %q", back[0].SeededAccountID)
	}
}

func TestAnApiKeyAccountIsSeededWithThePlaceholder(t *testing.T) {
	dir := t.TempDir()
	grant := Grant{AccountID: "k", Kind: wire.KindAPIKey, APIKey: "sk-real-key"}
	if err := Seed(dir, grant, noon); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, ".credentials.json"))
	if err != nil {
		t.Fatal(err)
	}
	// Claude Code refuses to start without a credential, so an API-key session gets one
	// that authenticates nothing; the proxy swaps in x-api-key on every request.
	if !containsToken(data, PlaceholderToken) {
		t.Fatalf("got %s", data)
	}
	// The real key must never reach the disk Claude Code reads.
	if bytes.Contains(data, []byte("sk-real-key")) {
		t.Fatalf("the api key was written into the namespace: %s", data)
	}
}

// The pool the league box saw: both Emcd seats in an organisation that has turned Claude
// Code off, and the most drained of everything still in it.
func emcdPool(fake *fakeServer) {
	emcdOrg, emcdName, winOrg := "org-emcd", "Emcd", "org-1win"
	fake.accounts = []wire.RemoteAccount{
		{ID: "emcd2", Label: "emcd2", Kind: wire.KindSubscription, Health: wire.HealthOK,
			OrganizationUUID: &emcdOrg, OrganizationName: &emcdName},
		{ID: "emcd", Label: "v.vislovich@emcd.io", Kind: wire.KindSubscription,
			Health: wire.HealthOK, OrganizationUUID: &emcdOrg, OrganizationName: &emcdName},
		{ID: "win", Label: "Win", Email: wire.Ptr("v@1win.example"),
			Kind: wire.KindSubscription, Health: wire.HealthOK, OrganizationUUID: &winOrg},
	}
	fake.usage["emcd2"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 69, "")}
	fake.usage["emcd"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 60, "")}
	fake.usage["win"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 7, "")}
	fake.tokens["emcd2"], fake.tokens["emcd"], fake.tokens["win"] = "t-e2", "t-e", "t-w"
}

func TestAnExcludedAccountIsNeverChosen(t *testing.T) {
	fake := newFakeServer(t)
	emcdPool(fake)
	// An organisation name covers every seat in it, whatever the case.
	daemon := newAgentWith(t, fake, func(c *config.Config) {
		c.Agent.ExcludeAccounts = []string{"EMCD"}
	})

	started, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "win" {
		t.Fatalf("started on %q, the most drained account not excluded is win",
			started.AccountID)
	}
	// Nor is one reached by failing over: with win refused there is nowhere left.
	if next, ok := daemon.Failover(started.SessionID, "claude-opus-5", "win",
		map[string]bool{"win": true}); ok {
		t.Fatalf("failed over to %q", next.AccountID)
	}
	// Naming one is refused, not quietly honoured.
	if _, err := daemon.NewSession(context.Background(), Launch{
		Model: "claude-opus-5", AccountID: "emcd2", PID: os.Getpid()}); err == nil ||
		!strings.Contains(err.Error(), "exclude_accounts") {
		t.Errorf("a launch pinned to an excluded account: %v", err)
	}
	if err := daemon.Assign(context.Background(), started.SessionID, "emcd",
		Explicit); err == nil {
		t.Error("an explicit move onto an excluded account was allowed")
	}
	for _, account := range daemon.Status().Accounts {
		if excluded := account.Unusable != ""; excluded != (account.ID != "win") {
			t.Errorf("%s: unusable %q", account.ID, account.Unusable)
		}
	}
}

// One seat refused for its organisation means every seat in it is refused, so the next
// pick goes outside the organisation rather than to its sibling.
func TestAnOrganisationRefusalHoldsEverySeatInIt(t *testing.T) {
	fake := newFakeServer(t)
	emcdPool(fake)
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "emcd2" {
		t.Fatalf("started on %q", started.AccountID)
	}

	daemon.OrganizationRefused("emcd2")
	next, ok := daemon.Failover(started.SessionID, "claude-opus-5", "emcd2",
		map[string]bool{"emcd2": true})
	if !ok || next.AccountID != "win" {
		t.Fatalf("failed over to %q (%v), want win, outside the organisation",
			next.AccountID, ok)
	}
	again, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if again.AccountID != "win" {
		t.Errorf("a later launch started on %q", again.AccountID)
	}
}

func TestAnAccountCanBeNamedByLabelOrEmail(t *testing.T) {
	fake := newFakeServer(t)
	emcdPool(fake)
	daemon := newAgent(t, fake)

	for _, name := range []string{"win", "Win", "v@1win.example"} {
		started, err := daemon.NewSession(context.Background(), Launch{
			Model: "claude-opus-5", AccountID: name, PID: os.Getpid()})
		if err != nil {
			t.Fatalf("%q: %v", name, err)
		}
		if started.AccountID != "win" {
			t.Errorf("%q started on %q", name, started.AccountID)
		}
	}
	if _, err := daemon.NewSession(context.Background(), Launch{
		Model: "claude-opus-5", AccountID: "nobody", PID: os.Getpid()}); err == nil {
		t.Error("an unknown account name was accepted")
	}
}

// A rotation names the exact id it picked: it must neither resolve a label to some other
// account nor land on an organisation refused since the pick.
func TestARotationMovesOnlyToTheExactUsableAccountItNamed(t *testing.T) {
	fake := newFakeServer(t)
	emcdPool(fake)
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if err := daemon.Assign(context.Background(), started.SessionID, "Win",
		Rotation); err == nil {
		t.Error("a rotation resolved a label")
	}
	daemon.OrganizationRefused("emcd2")
	if err := daemon.Assign(context.Background(), started.SessionID, "emcd",
		Rotation); err == nil {
		t.Error("a rotation moved onto a refused organisation")
	}
	daemon.mu.Lock()
	serving := daemon.sessions[started.SessionID].record.AccountID
	daemon.mu.Unlock()
	if serving != "emcd2" {
		t.Errorf("the refused moves still moved the session to %q", serving)
	}
}

// Waiting cannot fix a pool emptied by configuration, so it is not the exit 75 an
// application would queue on forever.
func TestAPoolEmptiedByExclusionIsAFailureNotAWait(t *testing.T) {
	fake := newFakeServer(t)
	emcdPool(fake)
	daemon := newAgentWith(t, fake, func(c *config.Config) {
		c.Agent.ExcludeAccounts = []string{"Emcd", "Win"}
	})
	_, err := daemon.NewSession(context.Background(),
		Launch{Model: "claude-opus-5", PID: os.Getpid()})
	var refusal *ErrNoAccount
	if err == nil || asNoAccount(err, &refusal) {
		t.Fatalf("got %v, want a plain failure", err)
	}
}

func subscription(id string, group string) wire.RemoteAccount {
	account := wire.RemoteAccount{ID: id, Label: id, Kind: wire.KindSubscription,
		Health: wire.HealthOK}
	if group != "" {
		account.GroupID = wire.Ptr(group)
	}
	return account
}

func spentUntil(at time.Time) []wire.UsageWindow {
	return []wire.UsageWindow{{Kind: wire.WindowWeeklyAll, Label: "Weekly", Percent: 100,
		ResetsAt: &wire.Time{Time: at}}}
}

// Two accounts reserved for League, one for Fast, and one in no group. Fast is the most
// drained of all, so anything that ignores the groups picks it.
func groupedPool(fake *fakeServer) {
	fake.groups = []wire.SubscriptionGroup{{ID: "g-league", Name: "League"},
		{ID: "g-fast", Name: "Fast"}}
	fake.accounts = []wire.RemoteAccount{subscription("league1", "g-league"),
		subscription("league2", "g-league"), subscription("fast", "g-fast"),
		subscription("free", "")}
	for id, percent := range map[string]float64{"league1": 70, "league2": 40, "fast": 90,
		"free": 10} {
		fake.usage[id] = []wire.UsageWindow{window(wire.WindowWeeklyAll, percent, "")}
		fake.tokens[id] = "tok-" + id
	}
}

func notAutomatic(daemon *Agent) map[string]string {
	out := map[string]string{}
	for _, account := range daemon.Status().Accounts {
		out[account.ID] = account.NotAutomatic
	}
	return out
}

func TestAnAccountOutOfRotationIsOnlyUsedWhenNamed(t *testing.T) {
	fake := newFakeServer(t)
	out := subscription("out", "")
	out.InRotation = wire.Ptr(false)
	fake.accounts = []wire.RemoteAccount{out, subscription("in", "")}
	fake.usage["out"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 90, "")}
	fake.usage["in"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 50, "")}
	fake.tokens["out"], fake.tokens["in"] = "tok-out", "tok-in"
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "in" {
		t.Fatalf("started on %q, though out is out of rotation", started.AccountID)
	}
	if next, ok := daemon.Failover(started.SessionID, "", "in",
		map[string]bool{"in": true}); ok {
		t.Fatalf("failed over to %q", next.AccountID)
	}
	if err := daemon.Assign(context.Background(), started.SessionID, "out",
		Rotation); err == nil {
		t.Error("a rotation moved onto an account out of rotation")
	}

	// A person naming it is the whole point of keeping it.
	pinned, err := daemon.NewSession(context.Background(),
		Launch{AccountID: "out", PID: os.Getpid()})
	if err != nil {
		t.Fatalf("a pin to an account out of rotation: %v", err)
	}
	if pinned.AccountID != "out" {
		t.Errorf("pinned run started on %q", pinned.AccountID)
	}
	if err := daemon.Assign(context.Background(), started.SessionID, "out",
		Explicit); err != nil {
		t.Errorf("an explicit move onto an account out of rotation: %v", err)
	}
	if got := notAutomatic(daemon); got["out"] != "out of rotation" || got["in"] != "" {
		t.Errorf("status reasons %q", got)
	}
}

// An API key bills per token, so spending it is a person's decision, as on the Mac.
func TestAnApiKeyIsOnlyUsedWhenNamed(t *testing.T) {
	fake := newFakeServer(t)
	fake.accounts = []wire.RemoteAccount{
		{ID: "key", Label: "Key", Kind: wire.KindAPIKey, Health: wire.HealthOK},
		subscription("sub", "")}
	fake.usage["sub"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 10, "")}
	fake.tokens["key"], fake.tokens["sub"] = "tok-key", "tok-sub"
	daemon := newAgent(t, fake)

	// With no windows the key ranks mid-pack, ahead of a subscription this fresh.
	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "sub" {
		t.Fatalf("started on %q", started.AccountID)
	}
	if pinned, err := daemon.NewSession(context.Background(),
		Launch{AccountID: "Key", PID: os.Getpid()}); err != nil || pinned.AccountID != "key" {
		t.Fatalf("a pin to the api key: %q, %v", pinned.AccountID, err)
	}
	if got := notAutomatic(daemon)["key"]; got != "API key — pin it with --account" {
		t.Errorf("status reason %q", got)
	}

	// With only the key left to choose, waiting fixes nothing.
	fake.accounts = fake.accounts[:1]
	if err := daemon.refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	_, err = daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	var refusal *ErrNoAccount
	if err == nil || asNoAccount(err, &refusal) {
		t.Fatalf("got %v, want a plain failure", err)
	}
}

// The moment to retry at must belong to an account a retry could actually get.
func TestARetryTimeIgnoresAccountsThatAreNotChosenAutomatically(t *testing.T) {
	fake := newFakeServer(t)
	out := subscription("out", "")
	out.InRotation = wire.Ptr(false)
	fake.accounts = []wire.RemoteAccount{subscription("in", ""), out,
		{ID: "key", Label: "Key", Kind: wire.KindAPIKey, Health: wire.HealthOK},
		subscription("reserved", "g-league")}
	fake.groups = []wire.SubscriptionGroup{{ID: "g-league", Name: "League"}}
	fake.usage["in"] = spentUntil(noon.Add(3 * time.Hour))
	fake.usage["out"] = spentUntil(noon.Add(time.Hour))
	fake.usage["reserved"] = spentUntil(noon.Add(2 * time.Hour))
	daemon := newAgent(t, fake)

	_, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	var refusal *ErrNoAccount
	if !asNoAccount(err, &refusal) {
		t.Fatalf("got %v, want ErrNoAccount", err)
	}
	if !refusal.At.Equal(noon.Add(3 * time.Hour)) {
		t.Errorf("retry at %v, want in's own reset", refusal.At)
	}
}

// Grouped accounts are reserved for the boxes limited to their group.
func TestABoxWithNoGroupNeverTakesAGroupedAccount(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "free" || started.Group != "" {
		t.Fatalf("started on %q in %q, want free in no group", started.AccountID,
			started.Group)
	}
	if next, ok := daemon.Failover(started.SessionID, "", "free",
		map[string]bool{"free": true}); ok {
		t.Fatalf("failed over to %q", next.AccountID)
	}
	if pinned, err := daemon.NewSession(context.Background(),
		Launch{AccountID: "fast", PID: os.Getpid()}); err != nil || pinned.AccountID != "fast" {
		t.Fatalf("a pin to a grouped account: %q, %v", pinned.AccountID, err)
	}

	status := daemon.Status()
	if status.Group != "" || status.GroupError != "" {
		t.Errorf("box group %q (%q)", status.Group, status.GroupError)
	}
	for _, account := range status.Accounts {
		want := map[string]string{"league1": "in group League", "league2": "in group League",
			"fast": "in group Fast", "free": ""}[account.ID]
		if account.NotAutomatic != want {
			t.Errorf("%s: %q, want %q", account.ID, account.NotAutomatic, want)
		}
	}
}

func TestABoxLimitedToAGroupUsesOnlyThatGroup(t *testing.T) {
	// By name ignoring case, or by exact id.
	for _, name := range []string{"league", "g-league"} {
		t.Run(name, func(t *testing.T) {
			fake := newFakeServer(t)
			groupedPool(fake)
			daemon := newAgentWith(t, fake, func(c *config.Config) { c.Agent.Group = name })

			started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
			if err != nil {
				t.Fatal(err)
			}
			if started.AccountID != "league1" || started.Group != "League" {
				t.Fatalf("started on %q in %q", started.AccountID, started.Group)
			}
			next, ok := daemon.Failover(started.SessionID, "", "league1",
				map[string]bool{"league1": true})
			if !ok || next.AccountID != "league2" {
				t.Fatalf("failed over to %q (%v), want league2", next.AccountID, ok)
			}
			if next, ok := daemon.Failover(started.SessionID, "", "league2",
				map[string]bool{"league1": true, "league2": true}); ok {
				t.Fatalf("spilled out of the group to %q", next.AccountID)
			}
			if err := daemon.Assign(context.Background(), started.SessionID, "free",
				Rotation); err == nil {
				t.Error("a rotation left the group")
			}

			pinned, err := daemon.NewSession(context.Background(),
				Launch{AccountID: "free", PID: os.Getpid()})
			if err != nil || pinned.AccountID != "free" {
				t.Fatalf("a pin outside the group: %q, %v", pinned.AccountID, err)
			}
			// The pin chose where it starts, not where it may be moved.
			if next, ok := daemon.Failover(pinned.SessionID, "", "free",
				map[string]bool{"free": true}); !ok || next.AccountID != "league1" {
				t.Errorf("the pinned run failed over to %q (%v)", next.AccountID, ok)
			}

			status := daemon.Status()
			if status.Group != "League" {
				t.Errorf("box group %q", status.Group)
			}
			got := notAutomatic(daemon)
			if got["league1"] != "" || got["free"] != "not in group League" ||
				got["fast"] != "not in group League" {
				t.Errorf("status reasons %q", got)
			}
		})
	}
}

// Spilling into the rest of the pool is exactly what limiting a box to a group forbids.
func TestASpentGroupIsAWaitForThatGroupAlone(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	fake.usage["league1"] = spentUntil(noon.Add(3 * time.Hour))
	fake.usage["league2"] = spentUntil(noon.Add(2 * time.Hour))
	fake.usage["fast"] = spentUntil(noon.Add(time.Hour))
	daemon := newAgentWith(t, fake, func(c *config.Config) { c.Agent.Group = "League" })

	_, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	var refusal *ErrNoAccount
	if !asNoAccount(err, &refusal) {
		t.Fatalf("got %v, want ErrNoAccount, though free has room", err)
	}
	if !refusal.At.Equal(noon.Add(2 * time.Hour)) {
		t.Errorf("retry at %v, want league2's reset", refusal.At)
	}
	if !strings.Contains(err.Error(), "group League") {
		t.Errorf("the refusal does not say which group: %v", err)
	}
	if fake.draws["free"] != 0 {
		t.Error("a credential was drawn outside the group")
	}
}

func TestARunsOwnGroupOverridesTheBoxsAndOutlivesARestart(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	fake.accounts = append(fake.accounts, subscription("fast2", "g-fast"))
	fake.usage["fast2"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 20, "")}
	fake.tokens["fast2"] = "tok-fast2"
	daemon := newAgentWith(t, fake, func(c *config.Config) { c.Agent.Group = "League" })

	started, err := daemon.NewSession(context.Background(),
		Launch{Group: "fast", PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "fast" || started.Group != "Fast" {
		t.Fatalf("started on %q in %q", started.AccountID, started.Group)
	}

	daemon = restart(t, daemon)
	if got := daemon.Status().Sessions; len(got) != 1 || got[0].Group != "Fast" {
		t.Fatalf("recovered sessions %+v", got)
	}
	next, ok := daemon.Failover(started.SessionID, "", "fast", map[string]bool{"fast": true})
	if !ok || next.AccountID != "fast2" {
		t.Fatalf("failed over to %q (%v), want fast2 inside the run's own group",
			next.AccountID, ok)
	}

	// The moment handed to Claude Code is the run's group's too, not the box's.
	fake.usage["fast"] = spentUntil(noon.Add(4 * time.Hour))
	fake.usage["fast2"] = spentUntil(noon.Add(5 * time.Hour))
	fake.usage["league1"] = spentUntil(noon.Add(time.Hour))
	if err := daemon.refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	at, ok := daemon.SoonestAvailability(started.SessionID, "")
	if !ok || !at.Equal(noon.Add(4*time.Hour)) {
		t.Errorf("soonest %v (%v), want fast's reset", at, ok)
	}
}

// A group that cannot be resolved is refused outright: guessing would spend accounts
// reserved for someone else, and waiting fixes none of these.
func TestAGroupThatCannotBeResolvedRefusesTheLaunch(t *testing.T) {
	for _, tc := range []struct {
		name     string
		boxGroup string
		runGroup string
		server   func(*fakeServer)
		want     string
	}{
		{name: "a ccmuxd without groups", boxGroup: "League",
			server: func(f *fakeServer) { f.features = []string{"sessions", "usage-series"} },
			want:   "has no groups"},
		{name: "a group the server does not have", boxGroup: "Leauge",
			want: `no group "Leauge"`},
		{name: "a group list never read", boxGroup: "League",
			server: func(f *fakeServer) { f.groupsDown = true },
			want:   "not been read"},
		{name: "a run's own unknown group", runGroup: "Nope", want: `no group "Nope"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fake := newFakeServer(t)
			groupedPool(fake)
			if tc.server != nil {
				tc.server(fake)
			}
			daemon, logged := newLoggedAgent(t, fake, func(c *config.Config) {
				c.Agent.Group = tc.boxGroup
			})
			for _, pin := range []string{"", "free"} {
				_, err := daemon.NewSession(context.Background(),
					Launch{Group: tc.runGroup, AccountID: pin, PID: os.Getpid()})
				var refusal *ErrNoAccount
				if err == nil || asNoAccount(err, &refusal) ||
					!strings.Contains(err.Error(), tc.want) {
					t.Errorf("pin %q: got %v, want a plain failure saying %q", pin, err,
						tc.want)
				}
			}
			for id, n := range fake.draws {
				t.Errorf("drew %d credentials for %s", n, id)
			}
			if tc.boxGroup == "" {
				return
			}
			warned := false
			for _, line := range *logged {
				warned = warned || strings.Contains(line, tc.want)
			}
			if !warned {
				t.Errorf("nothing logged at start: %q", *logged)
			}
			if status := daemon.Status(); !strings.Contains(status.GroupError, tc.want) {
				t.Errorf("status group error %q", status.GroupError)
			}
		})
	}
}

func TestAnUpgradedCcmuxdIsNoticedWithoutARestart(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	fake.features = []string{"sessions", "usage-series"}
	daemon := newAgentWith(t, fake, func(c *config.Config) { c.Agent.Group = "League" })
	if _, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()}); err == nil {
		t.Fatal("a launch limited to a group ran on a ccmuxd without groups")
	}
	if fake.groupReads != 0 {
		t.Errorf("asked a ccmuxd without groups for them %d times", fake.groupReads)
	}

	fake.features = append(fake.features, wire.FeatureGroups)
	daemon.housekeep(context.Background())
	if _, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()}); err == nil {
		t.Fatal("the features were re-read on every tick")
	}
	daemon.now = func() time.Time { return noon.Add(probeEvery) }
	daemon.housekeep(context.Background())
	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatalf("the upgrade went unnoticed: %v", err)
	}
	if started.AccountID != "league1" {
		t.Errorf("started on %q", started.AccountID)
	}
}

func TestTheLastKnownGroupsOutliveAFailedRead(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	daemon := newAgentWith(t, fake, func(c *config.Config) { c.Agent.Group = "League" })

	fake.groupsDown = true
	if err := daemon.refresh(context.Background()); err != nil {
		t.Fatalf("a failed group read failed the whole refresh: %v", err)
	}
	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "league1" {
		t.Errorf("started on %q", started.AccountID)
	}
}

// A group created after the list was last read is still a group: its account stays
// reserved rather than going to a box with no group.
func TestAnAccountInAGroupNotListedYetStaysReserved(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	fake.accounts = append(fake.accounts, subscription("newcomer", "g-new"))
	fake.usage["newcomer"] = []wire.UsageWindow{window(wire.WindowWeeklyAll, 80, "")}
	fake.tokens["newcomer"] = "tok-newcomer"
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID == "newcomer" {
		t.Error("a box with no group took an account reserved for a group it has not listed")
	}
}

// Without a list, a group cannot be shown to be gone, so its accounts stay reserved.
func TestBeforeTheGroupsAreReadAGroupedAccountStaysReserved(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	fake.groupsDown = true
	daemon := newAgent(t, fake)

	started, err := daemon.NewSession(context.Background(), Launch{PID: os.Getpid()})
	if err != nil {
		t.Fatal(err)
	}
	if started.AccountID != "free" {
		t.Errorf("started on %q before any group list was read", started.AccountID)
	}
}

// What an older shim cannot see: the group arrives over the socket, and the reply says
// which one applied.
func TestTheControlReplyEchoesTheGroupThatApplied(t *testing.T) {
	fake := newFakeServer(t)
	groupedPool(fake)
	daemon := newAgent(t, fake)

	response := daemon.Handle(context.Background(), control.Request{
		Op: control.OpNewSession, Group: "LEAGUE", PID: os.Getpid()})
	if !response.OK || response.Session == nil {
		t.Fatalf("got %+v", response)
	}
	if response.Session.Group != "League" || response.Session.AccountID != "league1" {
		t.Errorf("group %q on %q", response.Session.Group, response.Session.AccountID)
	}

	response = daemon.Handle(context.Background(), control.Request{
		Op: control.OpNewSession, PID: os.Getpid()})
	if !response.OK || response.Session.Group != "" {
		t.Errorf("a run with no group echoed %+v", response.Session)
	}
}
