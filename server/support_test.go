package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------- basic auth

func testCredential() BasicAuthCredential {
	sum := sha256.Sum256([]byte("hunter2"))
	return BasicAuthCredential{Username: "ccmux", PasswordHash: hex.EncodeToString(sum[:])}
}

func TestBasicAuthAcceptsTheRightCredential(t *testing.T) {
	if !testCredential().Accepts("ccmux", "hunter2") {
		t.Fatal("should have been accepted")
	}
}

func TestBasicAuthRefusesEverythingElse(t *testing.T) {
	c := testCredential()
	cases := [][2]string{
		{"ccmux", "hunter3"},
		{"someone", "hunter2"},
		// A prefix must not pass: the compare folds length into the result.
		{"ccmux", "hunter"},
		{"ccmu", "hunter2"},
		{"", ""},
	}
	for _, tc := range cases {
		if c.Accepts(tc[0], tc[1]) {
			t.Errorf("should have refused %q/%q", tc[0], tc[1])
		}
	}
}

func TestBasicAuthHeaderParsing(t *testing.T) {
	header := "Basic " + base64.StdEncoding.EncodeToString([]byte("ccmux:hunter2"))
	user, pass, ok := parseBasicAuth(header)
	if !ok || user != "ccmux" || pass != "hunter2" {
		t.Fatalf("got %q/%q ok=%v", user, pass, ok)
	}
}

// Split on the first colon only — a generated password may well contain one.
func TestAPasswordContainingAColonSurvives(t *testing.T) {
	header := "Basic " + base64.StdEncoding.EncodeToString([]byte("ccmux:pa:ss:word"))
	user, pass, ok := parseBasicAuth(header)
	if !ok || user != "ccmux" || pass != "pa:ss:word" {
		t.Fatalf("got %q/%q ok=%v", user, pass, ok)
	}
}

func TestRubbishHeadersAreRejectedRatherThanCrashing(t *testing.T) {
	for _, header := range []string{
		"Bearer abc",
		"Basic",
		"Basic !!!not-base64!!!",
		"Basic " + base64.StdEncoding.EncodeToString([]byte("nocolon")),
		"",
	} {
		if _, _, ok := parseBasicAuth(header); ok {
			t.Errorf("should have rejected %q", header)
		}
	}
}

func TestTheAuthFileMustBeUsernameAndASha256(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "auth")
	sum := sha256.Sum256([]byte("pw"))
	if err := os.WriteFile(good, []byte("ccmux:"+hex.EncodeToString(sum[:])+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadBasicAuth(good)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Accepts("ccmux", "pw") {
		t.Fatal("loaded credential should accept the password")
	}

	// A plaintext password in the file is the mistake worth catching loudly: it would
	// otherwise be hashed-and-compared against and never match.
	bad := filepath.Join(dir, "bad")
	_ = os.WriteFile(bad, []byte("ccmux:plaintext\n"), 0o600)
	if _, err := LoadBasicAuth(bad); err == nil {
		t.Fatal("a non-sha256 secret must be rejected")
	}
	if _, err := LoadBasicAuth(filepath.Join(dir, "absent")); err == nil {
		t.Fatal("a missing auth file must be rejected")
	}
}

// ---------------------------------------------------------------- secret store

func TestTheSealedFileRoundTrips(t *testing.T) {
	dir := t.TempDir()
	key, err := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewEncryptedFileStore(filepath.Join(dir, "s.sealed"), key)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Write("a", "value-one"); err != nil {
		t.Fatal(err)
	}
	if err := store.Write("b", "value-two"); err != nil {
		t.Fatal(err)
	}
	if v, ok, _ := store.Read("a"); !ok || v != "value-one" {
		t.Fatal("round trip failed")
	}
	if keys, _ := store.Keys(); len(keys) != 2 {
		t.Fatalf("expected 2 keys, got %v", keys)
	}
	if err := store.Delete("a"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := store.Read("a"); ok {
		t.Fatal("delete did not take")
	}

	// Reopened by a fresh instance with the same key, as a restart would.
	sameKey, _ := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	reopened, _ := NewEncryptedFileStore(filepath.Join(dir, "s.sealed"), sameKey)
	if v, ok, _ := reopened.Read("b"); !ok || v != "value-two" {
		t.Fatal("did not survive a reopen")
	}
}

func TestThePlaintextIsNotOnDisk(t *testing.T) {
	dir := t.TempDir()
	sealed := filepath.Join(dir, "s.sealed")
	key, _ := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	store, _ := NewEncryptedFileStore(sealed, key)
	if err := store.Write("acct", "a-refresh-token-shaped-thing"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "a-refresh-token-shaped-thing") {
		t.Fatal("the secret is sitting in plaintext on disk")
	}
}

// The failure that must never be quiet: opening with the wrong key has to fail, not
// return an empty map. Carrying on empty would overwrite every live refresh token on the
// very next write.
func TestAWrongKeyRefusesInsteadOfLookingEmpty(t *testing.T) {
	dir := t.TempDir()
	sealed := filepath.Join(dir, "s.sealed")
	right, _ := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	store, _ := NewEncryptedFileStore(sealed, right)
	_ = store.Write("k", "v")

	wrong, _ := LoadOrCreateMasterKey(filepath.Join(dir, "other.key"))
	broken, _ := NewEncryptedFileStore(sealed, wrong)
	if _, _, err := broken.Read("k"); err == nil {
		t.Fatal("reading with the wrong key must fail")
	}
	if _, err := broken.Keys(); err == nil {
		t.Fatal("listing with the wrong key must fail")
	}
	if err := broken.Write("k2", "v2"); err == nil {
		t.Fatal("writing with the wrong key must fail rather than clobber the file")
	}
}

func TestAMissingSealedFileIsSimplyEmpty(t *testing.T) {
	dir := t.TempDir()
	key, _ := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	store, _ := NewEncryptedFileStore(filepath.Join(dir, "absent.sealed"), key)
	if keys, err := store.Keys(); err != nil || len(keys) != 0 {
		t.Fatalf("expected empty, got %v %v", keys, err)
	}
	if _, ok, err := store.Read("anything"); ok || err != nil {
		t.Fatal("expected a clean miss")
	}
}

func TestTheMasterKeyIs0600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "master.key")
	if _, err := LoadOrCreateMasterKey(path); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("master key should be 0600, is %v", info.Mode().Perm())
	}
	// And it must be stable — regenerating it would orphan every stored credential.
	again, _ := LoadOrCreateMasterKey(path)
	first, _ := os.ReadFile(path)
	if string(again) != string(first) {
		t.Fatal("the master key must not be regenerated on reload")
	}
}

// OAuth credentials and API keys share one sealed file. They authenticate with different
// headers entirely, so an id colliding across the two would be a real confusion of
// credential shapes.
func TestPrefixesKeepTheTwoCredentialShapesApart(t *testing.T) {
	base := NewMemoryStore()
	oauth := NewPrefixedStore(base, "oauth:")
	keys := NewPrefixedStore(base, "apikey:")

	_ = oauth.Write("same-id", "credential-json")
	_ = keys.Write("same-id", "sk-ant-secret")

	if v, _, _ := oauth.Read("same-id"); v != "credential-json" {
		t.Fatal("oauth view returned the wrong value")
	}
	if v, _, _ := keys.Read("same-id"); v != "sk-ant-secret" {
		t.Fatal("api key view returned the wrong value")
	}
	if k, _ := oauth.Keys(); len(k) != 1 || k[0] != "same-id" {
		t.Fatalf("oauth keys wrong: %v", k)
	}
	_ = oauth.Delete("same-id")
	if v, _, _ := keys.Read("same-id"); v != "sk-ant-secret" {
		t.Fatal("deleting one view must not touch the other")
	}
}

// ---------------------------------------------------------------- config

func TestConfigFlags(t *testing.T) {
	config, err := ParseConfig([]string{"--data-dir", "/tmp/d", "--port", "9443",
		"--host", "127.0.0.1"}, func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	if config.DataDir != "/tmp/d" || config.Port != 9443 || config.Host != "127.0.0.1" {
		t.Fatalf("bad parse: %+v", config)
	}
	if config.Insecure {
		t.Fatal("insecure must default off")
	}
	if config.AccountsFile() != "/tmp/d/accounts.json" {
		t.Fatalf("bad accounts path: %s", config.AccountsFile())
	}
}

func TestConfigEnvironmentAndPrecedence(t *testing.T) {
	env := func(key string) string {
		if key == "CCMUXD_DATA_DIR" {
			return "/from/env"
		}
		return ""
	}
	config, _ := ParseConfig(nil, env)
	if config.DataDir != "/from/env" {
		t.Fatalf("env ignored: %s", config.DataDir)
	}
	config, _ = ParseConfig([]string{"--data-dir", "/from/flag"}, env)
	if config.DataDir != "/from/flag" {
		t.Fatal("the flag must beat the environment")
	}
}

func TestConfigRejectsBadInput(t *testing.T) {
	none := func(string) string { return "" }
	for _, args := range [][]string{
		{"--port"},
		{"--port", "70000"},
		{"--port", "0"},
		{"--port", "not-a-number"},
		{"--nonsense"},
	} {
		if _, err := ParseConfig(args, none); err == nil {
			t.Errorf("should have rejected %v", args)
		}
	}
}

// ---------------------------------------------------------------- usage parsing

func TestUsagePrefersTheLimitsArray(t *testing.T) {
	payload := map[string]any{
		"limits": []any{
			map[string]any{"kind": "session", "percent": 12.5,
				"resets_at": "2026-08-28T12:00:00.123Z"},
			map[string]any{"kind": "weekly_all", "percent": 40.0},
			map[string]any{"kind": "weekly_scoped", "percent": 60.0,
				"scope": map[string]any{"model": map[string]any{"display_name": "Fable"}}},
		},
		// Ignored when limits is present — it is the only place per-model windows appear.
		"five_hour": map[string]any{"utilization": 99.0},
	}
	windows := WindowsFromUsageResponse(payload)
	if len(windows) != 3 {
		t.Fatalf("expected 3 windows, got %d", len(windows))
	}
	if windows[0].Kind != WindowSession || windows[0].Percent != 12.5 {
		t.Fatalf("session window wrong: %+v", windows[0])
	}
	if windows[0].ResetsAt == nil {
		t.Fatal("fractional-second reset should have parsed")
	}
	if windows[2].Kind != WindowWeeklyScoped || windows[2].ModelName == nil ||
		*windows[2].ModelName != "Fable" {
		t.Fatalf("scoped window wrong: %+v", windows[2])
	}
	if windows[2].Label != "Weekly Fable" {
		t.Fatalf("scoped label wrong: %q", windows[2].Label)
	}
}

func TestUsageFallsBackToLegacyKeys(t *testing.T) {
	payload := map[string]any{
		"five_hour": map[string]any{"utilization": 10.0, "resets_at": "2026-08-28T12:00:00Z"},
		"seven_day": map[string]any{"utilization": 20.0},
	}
	windows := WindowsFromUsageResponse(payload)
	if len(windows) != 2 {
		t.Fatalf("expected 2, got %d", len(windows))
	}
	if windows[0].Kind != WindowSession || windows[1].Kind != WindowWeeklyAll {
		t.Fatalf("wrong kinds: %+v", windows)
	}
}

// A scoped window with no model name cannot be identified, so it is dropped rather than
// shown as an anonymous weekly.
func TestAScopedWindowWithoutAModelIsSkipped(t *testing.T) {
	payload := map[string]any{"limits": []any{
		map[string]any{"kind": "weekly_scoped", "percent": 60.0},
	}}
	if windows := WindowsFromUsageResponse(payload); len(windows) != 0 {
		t.Fatalf("expected it dropped, got %+v", windows)
	}
}

func TestAnUnknownLimitKindIsKeptRatherThanDropped(t *testing.T) {
	payload := map[string]any{"limits": []any{
		map[string]any{"kind": "some_new_thing", "percent": 5.0},
	}}
	windows := WindowsFromUsageResponse(payload)
	if len(windows) != 1 || windows[0].Kind != WindowOther {
		t.Fatalf("expected one 'other' window, got %+v", windows)
	}
	if windows[0].Label != "Some new thing" {
		t.Fatalf("label should be sentence case, got %q", windows[0].Label)
	}
}

func TestEmptyUsageResponseYieldsNoWindows(t *testing.T) {
	if w := WindowsFromUsageResponse(map[string]any{}); len(w) != 0 {
		t.Fatalf("expected none, got %+v", w)
	}
	if w := WindowsFromUsageResponse(map[string]any{"limits": []any{}}); len(w) != 0 {
		t.Fatalf("expected none, got %+v", w)
	}
}

func TestHeadroomIsClamped(t *testing.T) {
	if got := (UsageWindow{Percent: 120}).Headroom(); got != 0 {
		t.Fatalf("headroom should never go negative, got %v", got)
	}
	if got := (UsageWindow{Percent: 25}).Headroom(); got != 75 {
		t.Fatalf("expected 75, got %v", got)
	}
}

// ---------------------------------------------------------------- poll policy

func TestRateLimitedPollsBackOff(t *testing.T) {
	now := time.Now()
	plan := PlanPoll(true, nil, UsageSnapshot{}, 3, true, now)
	if plan.Interval != pollRateLimitBackoff {
		t.Fatalf("expected the backoff interval, got %v", plan.Interval)
	}
	if !plan.NextPollAt.After(now) {
		t.Fatal("next poll must be in the future")
	}
}

func TestAnIdleAccountPollsSlowly(t *testing.T) {
	previous := UsageSnapshot{Windows: []UsageWindow{
		{Kind: WindowSession, Label: "5-hour", Percent: 10}}}
	current := previous
	plan := PlanPoll(false, &previous, current, 3, false, time.Now())
	if plan.Interval != pollIdleMax {
		t.Fatalf("an idle, unmoving account should use the idle max, got %v", plan.Interval)
	}
}

// The endpoint budgets ~28 requests an hour per token, so the floor exists to stop an
// active account burning it.
func TestAnActiveAccountNearItsThresholdPollsUrgently(t *testing.T) {
	previous := UsageSnapshot{Windows: []UsageWindow{
		{Kind: WindowSession, Label: "5-hour", Percent: 80}}}
	current := UsageSnapshot{Windows: []UsageWindow{
		{Kind: WindowSession, Label: "5-hour", Percent: 95}}}
	plan := PlanPoll(true, &previous, current, 3, false, time.Now())
	if plan.Interval != pollUrgentInterval {
		t.Fatalf("expected the urgent interval, got %v", plan.Interval)
	}
}

func TestJitterStaysWithinTenPercent(t *testing.T) {
	for i := 0; i < 200; i++ {
		got := jitter(300 * time.Second)
		if got < 270*time.Second || got > 330*time.Second {
			t.Fatalf("jitter out of range: %v", got)
		}
	}
}

func TestMovementIsInfiniteWithNoPrevious(t *testing.T) {
	if got := movement(nil, UsageSnapshot{}); !math.IsInf(got, 1) {
		t.Fatalf("a first sample should always count as movement, got %v", got)
	}
}

// ---------------------------------------------------------------- vault

// Look-up and insert used to be separate critical sections in the Swift original, so two
// callers could each see an empty slot and both POST the same refresh token at the same
// time. Anthropic rotates them, so the loser got invalid_grant and a healthy account was
// marked as needing re-login. Overlap is the property that matters, not the total count.
func TestRefreshGrantsNeverOverlapForOneAccount(t *testing.T) {
	var inFlight, peak, total int32
	var mu sync.Mutex

	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		current := atomic.AddInt32(&inFlight, 1)
		atomic.AddInt32(&total, 1)
		mu.Lock()
		if current > peak {
			peak = current
		}
		mu.Unlock()
		time.Sleep(150 * time.Millisecond)
		atomic.AddInt32(&inFlight, -1)
		return jsonResponse(200,
			`{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}`), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1",
		ExpiresAt: time.Now().Add(-time.Minute)})

	var wg sync.WaitGroup
	results := make([]string, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			if c, ok := vault.Refresh(context.Background(), "acct"); ok {
				results[idx] = c.AccessToken
			}
		}(i)
	}
	wg.Wait()

	mu.Lock()
	observedPeak := peak
	mu.Unlock()
	if observedPeak != 1 {
		t.Fatalf("grants overlapped: peak concurrency %d", observedPeak)
	}
	if atomic.LoadInt32(&total) < 1 {
		t.Fatal("no grant ran at all")
	}
	for i, got := range results {
		// Every caller gets the rotated credential rather than nothing.
		if got != "rotated" {
			t.Fatalf("caller %d got %q", i, got)
		}
	}
	if c, _ := vault.Credential("acct"); c.RefreshToken != "r2" {
		t.Fatal("the rotated refresh token was not stored")
	}
}

// And the slot must be released, so a later refresh is still possible.
func TestALaterRefreshIsNotBlockedByTheFinishedOne(t *testing.T) {
	var total int32
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		atomic.AddInt32(&total, 1)
		return jsonResponse(200, `{"access_token":"rotated","expires_in":28800}`), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1",
		ExpiresAt: time.Now().Add(-time.Minute)})

	for i := 0; i < 3; i++ {
		if _, ok := vault.Refresh(context.Background(), "acct"); !ok {
			t.Fatalf("refresh %d failed", i)
		}
	}
	if atomic.LoadInt32(&total) != 3 {
		t.Fatalf("expected 3 sequential grants, got %d", total)
	}
}

// A permanent failure is the re-login signal; a transient one must not be.
func TestOnlyAPermanentFailureIsReportedAsSuch(t *testing.T) {
	cases := []struct {
		body      string
		status    int
		permanent bool
	}{
		{`{"error":"invalid_grant"}`, 400, true},
		{`upstream is having a day`, 503, false},
		{`{"error":"teapot"}`, 400, false},
	}
	for _, tc := range cases {
		transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return jsonResponse(tc.status, tc.body), nil
		})
		var reported error
		vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}},
			NewMemoryStore())
		vault.OnRefreshFailure = func(_ string, err error) { reported = err }
		vault.Store("acct", Credential{AccessToken: "a", RefreshToken: "r1"})
		vault.Refresh(context.Background(), "acct")

		if reported == nil {
			t.Fatalf("no failure reported for %q", tc.body)
		}
		if IsPermanent(reported) != tc.permanent {
			t.Errorf("%q: permanent=%v, want %v", tc.body, IsPermanent(reported), tc.permanent)
		}
	}
}

// A credential with no refresh token cannot be refreshed, and saying so permanently is
// correct — only a fresh sign-in recovers it.
func TestRefreshingWithoutARefreshTokenIsPermanent(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		t.Error("no request should have been made")
		return jsonResponse(200, "{}"), nil
	})
	var reported error
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.OnRefreshFailure = func(_ string, err error) { reported = err }
	vault.Store("acct", Credential{AccessToken: "a"})
	if _, ok := vault.Refresh(context.Background(), "acct"); ok {
		t.Fatal("should not have succeeded")
	}
	if !IsPermanent(reported) {
		t.Fatalf("expected a permanent failure, got %v", reported)
	}
}

// A failed refresh must leave what we hold intact rather than blanking it.
func TestAFailedRefreshKeepsTheStoredCredential(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return jsonResponse(503, "nope"), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "kept", RefreshToken: "r1"})
	vault.Refresh(context.Background(), "acct")
	if c, _ := vault.Credential("acct"); c.AccessToken != "kept" {
		t.Fatalf("credential was damaged: %q", c.AccessToken)
	}
}

// readFileString is used by the suites that assert on sealed-file contents.
func readFileString(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// The message a user actually reads when adopt fails. Swift extracted `error.message`;
// the raw body is not an explanation.
func TestUpstreamErrorsSurfaceTheAPIMessage(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return jsonResponse(401,
			`{"type":"error","error":{"type":"authentication_error",`+
				`"message":"invalid x-api-key"}}`), nil
	})
	client := &OAuthClient{HTTP: &http.Client{Transport: transport}}
	err := client.ValidateAPIKey(context.Background(), "sk-ant-bogus")
	if err == nil {
		t.Fatal("expected a failure")
	}
	if err.Error() != "invalid x-api-key" {
		t.Fatalf("expected the API's own message, got %q", err.Error())
	}
	// A 401 without invalid_grant is still transient — only a dead lineage is permanent.
	if IsPermanent(err) {
		t.Fatal("a rejected API key is not a dead OAuth lineage")
	}
}

// A first poll that fails must not report an age of two thousand years.
func TestAFailedFirstPollDoesNotReportAnAbsurdAge(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {503, "upstream is having a day"},
	})
	registry, _ := newTestRegistry(t, stub)
	if _, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))}); err != nil {
		t.Fatal(err)
	}
	registry.record("acct-1", nil, transientError("upstream is having a day"))
	usage, ok := registry.Usage("acct-1")
	if !ok {
		t.Fatal("expected a snapshot")
	}
	if usage.AgeSeconds > 60 {
		t.Fatalf("age should be stamped at now, got %v seconds", usage.AgeSeconds)
	}
}

// A refresh grant rotates the token on Anthropic's side the moment they process it. If the
// caller's context is cancelled mid-flight — a Mac that hung up, its 20s URLSession
// timeout, a SIGTERM during a housekeeping tick — and the grant is abandoned, the rotated
// credential is never stored, the next refresh is told invalid_grant, and the account is
// permanently logged out.
//
// The Swift original was immune by accident: it ran the grant in an unstructured Task,
// which outlives the awaiting one.
func TestACancelledCallerDoesNotAbortTheRotation(t *testing.T) {
	started := make(chan struct{})
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(started)
		// Long enough that the caller's cancellation lands while we are in flight. If the
		// grant were on the caller's context, r.Context() would already be done here.
		time.Sleep(200 * time.Millisecond)
		select {
		case <-r.Context().Done():
			return nil, r.Context().Err()
		default:
		}
		return jsonResponse(200,
			`{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}`), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1",
		ExpiresAt: time.Now().Add(-time.Minute)})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan bool, 1)
	go func() {
		_, ok := vault.Refresh(ctx, "acct")
		done <- ok
	}()

	<-started
	cancel() // the client hangs up while Anthropic is processing the rotation

	if ok := <-done; !ok {
		t.Fatal("the grant was abandoned when the caller went away")
	}
	stored, _ := vault.Credential("acct")
	if stored.RefreshToken != "r2" {
		t.Fatalf("the rotated refresh token was lost: %q", stored.RefreshToken)
	}
	if stored.AccessToken != "rotated" {
		t.Fatalf("the rotated access token was lost: %q", stored.AccessToken)
	}
}

// And a delete racing an in-flight refresh must not resurrect the credential: storing it
// afterwards leaves a live refresh token orphaned in the sealed file.
func TestARemovalDuringARefreshDiscardsTheResult(t *testing.T) {
	started := make(chan struct{})
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(started)
		time.Sleep(150 * time.Millisecond)
		return jsonResponse(200,
			`{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}`), nil
	})
	secrets := NewMemoryStore()
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, secrets)
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1",
		ExpiresAt: time.Now().Add(-time.Minute)})

	done := make(chan struct{})
	go func() { vault.Refresh(context.Background(), "acct"); close(done) }()

	<-started
	vault.Forget("acct")
	<-done

	if _, ok := vault.Credential("acct"); ok {
		t.Fatal("the removed account came back in memory")
	}
	if _, ok, _ := secrets.Read("acct"); ok {
		t.Fatal("a live refresh token was left orphaned in the store after removal")
	}
}

// Detaching the grant's context stops a cancelled *caller* killing a rotation. It does
// not stop the process exiting out from under one — and `systemctl restart` is enough.
// Shutdown therefore waits for in-flight grants.
func TestShutdownWaitsForAnInFlightRotation(t *testing.T) {
	started := make(chan struct{})
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(started)
		time.Sleep(250 * time.Millisecond)
		return jsonResponse(200,
			`{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}`), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1",
		ExpiresAt: time.Now().Add(-time.Minute)})

	go vault.Refresh(context.Background(), "acct")
	<-started

	if !vault.WaitForGrants(5 * time.Second) {
		t.Fatal("the wait timed out while a grant was in flight")
	}
	// Having waited, the rotation must be on disk — that is the whole point.
	stored, _ := vault.Credential("acct")
	if stored.RefreshToken != "r2" {
		t.Fatalf("shutdown returned before the rotation was stored: %q", stored.RefreshToken)
	}
}

// And it must not block when there is nothing to wait for.
func TestWaitingForGrantsReturnsImmediatelyWhenIdle(t *testing.T) {
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: newStub(nil)}},
		NewMemoryStore())
	start := time.Now()
	if !vault.WaitForGrants(2 * time.Second) {
		t.Fatal("an idle vault should not time out")
	}
	if time.Since(start) > time.Second {
		t.Fatalf("waited %v with nothing in flight", time.Since(start))
	}
}

// A grant that never finishes must not hold the process open forever.
func TestWaitingForGrantsGivesUp(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{})
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		close(started)
		<-release
		return jsonResponse(200, `{"access_token":"x","expires_in":1}`), nil
	})
	vault := NewVault(&OAuthClient{HTTP: &http.Client{Transport: transport}}, NewMemoryStore())
	vault.Store("acct", Credential{AccessToken: "old", RefreshToken: "r1"})
	go vault.Refresh(context.Background(), "acct")
	<-started

	if vault.WaitForGrants(200 * time.Millisecond) {
		t.Fatal("should have given up on a grant that never finishes")
	}
	close(release)
}
