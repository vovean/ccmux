package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"ccmuxagent/internal/client"
	"ccmuxagent/internal/config"
	"ccmuxd/wire"
)

var noon = time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)

// A fake ccmuxd serving the wire shapes the agent needs.
type fakeServer struct {
	accounts []wire.RemoteAccount
	usage    map[string][]wire.UsageWindow
	tokens   map[string]string
	// Requests for a token, per account, so a test can prove one was drawn once.
	draws map[string]int
	http  *httptest.Server
}

func newFakeServer(t *testing.T) *fakeServer {
	t.Helper()
	fake := &fakeServer{
		usage:  map[string][]wire.UsageWindow{},
		tokens: map[string]string{},
		draws:  map[string]int{},
	}
	mux := http.NewServeMux()
	write := func(w http.ResponseWriter, payload any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(payload)
	}
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.HealthResponse{APIVersion: wire.APIVersion,
			Features: []string{"sessions", "hooks", "usage-series"}})
	})
	mux.HandleFunc("GET /v1/accounts", func(w http.ResponseWriter, _ *http.Request) {
		write(w, wire.AccountListResponse{APIVersion: wire.APIVersion, Accounts: fake.accounts})
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
	api, cfg := fake.client(t)
	daemon, err := New(cfg, api, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	daemon.now = func() time.Time { return noon }
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
