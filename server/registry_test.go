package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// stubTransport routes by path suffix, so one stub can serve a profile call, a token
// exchange and a usage fetch in the same test.
type stubTransport struct {
	routes map[string]stubReply

	// Guarded: the vault refreshes concurrently, so several goroutines reach RoundTrip at
	// once and an unsynchronised map here is a racy test, not a racy server.
	mu    sync.Mutex
	calls map[string]int
}

type stubReply struct {
	status int
	body   string
}

func newStub(routes map[string]stubReply) *stubTransport {
	return &stubTransport{routes: routes, calls: map[string]int{}}
}

func (s *stubTransport) count(suffix string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls[suffix]
}

func (s *stubTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	for suffix, reply := range s.routes {
		if strings.HasSuffix(r.URL.Path, suffix) {
			s.mu.Lock()
			s.calls[suffix]++
			s.mu.Unlock()
			return &http.Response{
				StatusCode: reply.status,
				Body:       io.NopCloser(strings.NewReader(reply.body)),
				Header:     http.Header{},
				Request:    r,
			}, nil
		}
	}
	return &http.Response{
		StatusCode: 404,
		Body:       io.NopCloser(strings.NewReader(`{"error":"no stub"}`)),
		Header:     http.Header{},
		Request:    r,
	}, nil
}

const profileJSON = `{"account":{"uuid":"acct-1","email":"someone@example.com"},
 "organization":{"uuid":"org-1","name":"Example","organization_type":"claude_team",
                 "rate_limit_tier":"tier_x"}}`

func newTestRegistry(t *testing.T, stub *stubTransport) (*Registry, *MemoryStore) {
	t.Helper()
	dir := t.TempDir()
	secrets := NewMemoryStore()
	client := &OAuthClient{HTTP: &http.Client{Transport: stub, Timeout: 5 * time.Second}}
	return NewRegistry(client, secrets, filepath.Join(dir, "accounts.json")), secrets
}

func credentialJSON(access, refresh string, expiresAt time.Time) string {
	return Credential{AccessToken: access, RefreshToken: refresh,
		ExpiresAt: expiresAt}.JSONString()
}

// The invariant the entire client-server split rests on: a refresh token enters the
// server and never comes back out. Two holders of one lineage means the loser of the next
// rotation is told invalid_grant and is logged out for good.
func TestATokenGrantNeverCarriesTheRefreshToken(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	registry, secrets := newTestRegistry(t, stub)

	const secret = "refresh-token-that-must-never-leave"
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("access-1", secret, time.Now().Add(time.Hour)))})
	if err != nil {
		t.Fatal(err)
	}

	grant, ok := registry.Token(context.Background(), "acct-1")
	if !ok {
		t.Fatal("expected a grant")
	}
	encoded, _ := json.Marshal(grant)
	if strings.Contains(string(encoded), secret) {
		t.Fatalf("the refresh token reached the wire: %s", encoded)
	}
	// And it really is being held — the omission is deliberate, not an empty vault.
	stored, ok, _ := secrets.Read("oauth:acct-1")
	if !ok || !strings.Contains(stored, secret) {
		t.Fatal("the server should be holding the refresh token")
	}
}

// ExpiresIn is seconds rather than a timestamp: the server and a laptop do not agree on
// the wall clock, and a client trusting a remote absolute time would treat tokens as live
// that the API considers dead.
func TestTokenLifeIsReportedAsRemainingSeconds(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	registry, _ := newTestRegistry(t, stub)
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))})
	if err != nil {
		t.Fatal(err)
	}
	grant, _ := registry.Token(context.Background(), "acct-1")
	if grant.ExpiresIn == nil || *grant.ExpiresIn <= 3500 || *grant.ExpiresIn > 3600 {
		t.Fatalf("expected ~3600s of life, got %v", grant.ExpiresIn)
	}
}

func TestAnExpiringTokenIsRefreshedBeforeItIsHandedOver(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
		"/v1/oauth/token": {200,
			`{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}`},
	})
	registry, _ := newTestRegistry(t, stub)
	// Two minutes left: inside the ten-minute floor.
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("nearly-dead", "r1",
			time.Now().Add(2*time.Minute)))})
	if err != nil {
		t.Fatal(err)
	}
	grant, ok := registry.Token(context.Background(), "acct-1")
	if !ok || grant.AccessToken == nil || *grant.AccessToken != "rotated" {
		t.Fatalf("expected the rotated token, got %v", grant.AccessToken)
	}
}

// A refresh that fails still yields the token we hold, provided it is still live:
// returning nothing parks a live session for certain, whereas the API may honour it.
func TestAFailedRefreshStillReturnsALiveToken(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
		"/v1/oauth/token":    {503, "upstream is having a day"},
	})
	registry, _ := newTestRegistry(t, stub)
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("old-but-fine", "r1",
			time.Now().Add(time.Minute)))})
	if err != nil {
		t.Fatal(err)
	}
	grant, ok := registry.Token(context.Background(), "acct-1")
	if !ok || *grant.AccessToken != "old-but-fine" {
		t.Fatal("should have handed back the token we hold")
	}
}

// The other half: a token that is ALREADY expired must be refused rather than handed
// over. A client that overwrote its own working refresh token with the corpse would lose
// the account for good.
func TestAnExpiredTokenWhoseRefreshFailedIsRefused(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
		"/v1/oauth/token":    {503, "upstream is having a day"},
	})
	registry, _ := newTestRegistry(t, stub)
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("long-dead", "r1",
			time.Now().Add(-time.Hour)))})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := registry.Token(context.Background(), "acct-1"); ok {
		t.Fatal("an expired token must be refused, not handed over")
	}
}

// An API-key account's id is a UUID generated by whichever Mac added it, so two machines
// disagree about it. Matching on the key's fingerprint is the only thing that stops the
// second Mac creating a duplicate.
func TestAnAPIKeyIsMatchedByFingerprintNotByID(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, _ := newTestRegistry(t, stub)

	first, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-example"), Label: ptr("from mac one")})
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-example"), Label: ptr("from mac two")})
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID {
		t.Fatal("the same key must land on the same account")
	}
	if second.Label != "from mac two" {
		t.Fatal("the label should be updated")
	}
	if len(registry.List()) != 1 {
		t.Fatalf("expected one account, got %d", len(registry.List()))
	}
	if first.APIKeyFingerprint == nil ||
		*first.APIKeyFingerprint != APIKeyFingerprint("sk-ant-example") {
		t.Fatal("fingerprint not recorded")
	}
}

func TestADifferentAPIKeyIsADifferentAccount(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, _ := newTestRegistry(t, stub)
	if _, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-one")}); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-two")}); err != nil {
		t.Fatal(err)
	}
	if len(registry.List()) != 2 {
		t.Fatalf("expected two accounts, got %d", len(registry.List()))
	}
}

func TestAnInvalidAPIKeyIsNotAdopted(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/v1/models": {401, `{"error":{"message":"invalid x-api-key"}}`}})
	registry, _ := newTestRegistry(t, stub)
	if _, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-bogus")}); err == nil {
		t.Fatal("a rejected key must not be stored")
	}
	if len(registry.List()) != 0 {
		t.Fatal("nothing should have been recorded")
	}
}

// The PKCE verifier stays on the server for the whole login, which is what makes the
// authorization code worthless to anyone who intercepts it on the way back.
func TestTheAuthorizeURLRedirectsToTheClientsOwnLoopback(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	started, err := registry.StartLogin(LoginStartRequest{RedirectPort: 54321})
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(started.AuthorizeURL)
	if err != nil {
		t.Fatal(err)
	}
	q := parsed.Query()
	if q.Get("redirect_uri") != "http://localhost:54321/callback" {
		t.Fatalf("redirect must stay on the client's loopback, got %q",
			q.Get("redirect_uri"))
	}
	if q.Get("code_challenge_method") != "S256" {
		t.Fatal("PKCE method must be S256")
	}
	if q.Get("state") != started.State {
		t.Fatal("state must be echoed so the client can check it")
	}
	if q.Get("code_challenge") == "" {
		t.Fatal("no challenge sent")
	}
	// Only the digest may travel; the verifier is the secret.
	if strings.Contains(started.AuthorizeURL, q.Get("code_challenge")+"=") {
		t.Fatal("challenge should be base64url without padding")
	}
}

func TestALoginWithTheWrongStateIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	started, _ := registry.StartLogin(LoginStartRequest{RedirectPort: 1234})
	_, err := registry.FinishLogin(context.Background(), LoginFinishRequest{
		LoginID: started.LoginID, Code: "abc", State: ptr("not-the-state")})
	if err == nil {
		t.Fatal("a mismatched state must be refused")
	}
}

func TestAnUnknownLoginIDIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	_, err := registry.FinishLogin(context.Background(),
		LoginFinishRequest{LoginID: "never-issued", Code: "abc"})
	if err == nil {
		t.Fatal("an unknown login id must be refused")
	}
}

// A login is single-use: replaying the same id must not exchange the code twice.
func TestALoginIDIsConsumed(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/oauth/token": {503, "nope"}})
	registry, _ := newTestRegistry(t, stub)
	started, _ := registry.StartLogin(LoginStartRequest{RedirectPort: 1234})
	_, _ = registry.FinishLogin(context.Background(),
		LoginFinishRequest{LoginID: started.LoginID, Code: "abc"})
	_, err := registry.FinishLogin(context.Background(),
		LoginFinishRequest{LoginID: started.LoginID, Code: "abc"})
	if err == nil {
		t.Fatal("the login id should have been consumed by the first attempt")
	}
}

// An account in the file with no credential behind it must be visibly broken rather than
// 404ing on every token request with nothing saying why.
func TestAnAccountWithNoStoredCredentialIsMarkedNeedsRelogin(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	saveAccountsFile(path, []RemoteAccount{{ID: "orphan", Label: "Orphan",
		Kind: KindSubscription, Health: HealthOK}})

	client := &OAuthClient{HTTP: &http.Client{Transport: newStub(nil)}}
	registry := NewRegistry(client, NewMemoryStore(), path)
	registry.Bootstrap()

	accounts := registry.List()
	if len(accounts) != 1 || accounts[0].Health != HealthNeedsRelogin {
		t.Fatalf("expected the orphan flagged, got %+v", accounts)
	}
	if _, ok := registry.Token(context.Background(), "orphan"); ok {
		t.Fatal("it cannot serve a token")
	}
}

func TestRemovingAnAccountDropsItsSecret(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, secrets := newTestRegistry(t, stub)
	account, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-gone")})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := secrets.Read("apikey:" + account.ID); !ok {
		t.Fatal("the key should have been stored")
	}
	if err := registry.Remove(account.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := secrets.Read("apikey:" + account.ID); ok {
		t.Fatal("the key should be gone")
	}
	if len(registry.List()) != 0 {
		t.Fatal("the account should be gone")
	}
}

func TestRemovingAnUnknownAccountIsRejected(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	if err := registry.Remove("nope"); err == nil {
		t.Fatal("expected a rejection")
	}
}

// Adopt must answer as soon as the credential is safe. Fetching usage inline, after a
// profile call that can itself take 15s, meant the server could still be working at the
// 20s point where the client gives up — and a client that concludes the adopt failed
// keeps its refresh token while the server already has one.
func TestAdoptDoesNotWaitOnTheUsageFetch(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	registry, _ := newTestRegistry(t, stub)

	account, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))})
	if err != nil {
		t.Fatal(err)
	}
	if account.ID != "acct-1" {
		t.Fatalf("unexpected account %q", account.ID)
	}
	// Returned with the credential stored and immediately usable — that is the contract.
	if _, ok := registry.Token(context.Background(), "acct-1"); !ok {
		t.Fatal("the credential should be live the moment adopt returns")
	}
}

// The profile is the fallback, not an afterthought: a token exchange can hand back a
// credential with no plan, and a session seeded without one is read by Claude Code as
// having no entitlements at all.
func TestThePlanIsTakenFromTheProfileWhenTheCredentialHasNone(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	registry, _ := newTestRegistry(t, stub)
	_, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))})
	if err != nil {
		t.Fatal(err)
	}
	account := registry.List()[0]
	// claude_team -> team, the spelling Claude Code's credential uses.
	if account.SubscriptionType == nil || *account.SubscriptionType != "team" {
		t.Fatalf("plan not backfilled from the profile: %v", account.SubscriptionType)
	}
	if account.RateLimitTier == nil || *account.RateLimitTier != "tier_x" {
		t.Fatalf("tier not backfilled: %v", account.RateLimitTier)
	}
	grant, _ := registry.Token(context.Background(), "acct-1")
	if grant.SubscriptionType == nil || *grant.SubscriptionType != "team" {
		t.Fatal("the grant must carry the plan, or models are silently withheld")
	}
}

func TestAccountsSurviveARestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	secrets := NewMemoryStore()
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	client := &OAuthClient{HTTP: &http.Client{Transport: stub}}

	first := NewRegistry(client, secrets, path)
	first.Bootstrap()
	if _, err := first.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))}); err != nil {
		t.Fatal(err)
	}

	second := NewRegistry(client, secrets, path)
	second.Bootstrap()
	accounts := second.List()
	if len(accounts) != 1 || accounts[0].Health != HealthOK {
		t.Fatalf("account did not survive the restart: %+v", accounts)
	}
	if _, ok := second.Token(context.Background(), "acct-1"); !ok {
		t.Fatal("the credential did not survive the restart")
	}
}

func TestAccountsFileIsWrittenAt0600(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")
	client := &OAuthClient{HTTP: &http.Client{Transport: stub}}
	registry := NewRegistry(client, NewMemoryStore(), path)
	if _, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-perm")}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("accounts.json should be 0600, is %v", info.Mode().Perm())
	}
}
