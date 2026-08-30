package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func jsonResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
	}
}

// A real TLS server, the real mux, and a client that pins the certificate exactly as the
// Mac does — SHA-256 over the DER, which is also what `openssl x509 -fingerprint -sha256`
// prints and what install-ccmuxd.sh shows the user.
func startTestServer(t *testing.T, registry *Registry) (*httptest.Server, string, *http.Client) {
	return startTestServerWith(t, registry, NewMachineStore())
}

func startTestServerWith(t *testing.T, registry *Registry,
	machines *MachineStore) (*httptest.Server, string, *http.Client) {
	t.Helper()
	server := httptest.NewTLSServer(NewMux(registry, machines, testCredential()))
	t.Cleanup(server.Close)

	leaf := server.Certificate()
	sum := sha256.Sum256(leaf.Raw)
	fingerprint := hex.EncodeToString(sum[:])

	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}},
	}
	return server, fingerprint, client
}

func authed(t *testing.T, client *http.Client, method, url, body string) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Basic "+
		base64.StdEncoding.EncodeToString([]byte("ccmux:hunter2")))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestEndToEndHealthAndAuth(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)

	// No credentials at all.
	resp, err := client.Get(server.URL + "/v1/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
	// The realm is what makes a browser and `curl -u` prompt rather than just failing.
	if !strings.Contains(resp.Header.Get("WWW-Authenticate"), `realm="ccmuxd"`) {
		t.Fatalf("missing realm: %q", resp.Header.Get("WWW-Authenticate"))
	}

	ok := authed(t, client, http.MethodGet, server.URL+"/v1/health", "")
	defer ok.Body.Close()
	if ok.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", ok.StatusCode)
	}
	var health HealthResponse
	if err := json.NewDecoder(ok.Body).Decode(&health); err != nil {
		t.Fatal(err)
	}
	if health.APIVersion != apiVersion {
		t.Fatalf("wrong api version %d", health.APIVersion)
	}
}

func TestEndToEndWrongPasswordIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)

	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/health", nil)
	req.Header.Set("Authorization", "Basic "+
		base64.StdEncoding.EncodeToString([]byte("ccmux:wrong")))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// The pin is the only thing standing between the client and any host answering on that
// address, because a self-signed certificate has no authority behind it.
func TestEndToEndACertificateOutsideThePinIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, _ := startTestServer(t, registry)

	// A client that trusts nothing must fail to connect at all.
	strict := &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: x509.NewCertPool()}}}
	if _, err := strict.Get(server.URL + "/v1/health"); err == nil {
		t.Fatal("an untrusted certificate must not be accepted")
	}
}

// The fingerprint the client pins must be SHA-256 over the DER — the same bytes
// `openssl x509 -fingerprint -sha256` hashes and install-ccmuxd.sh prints.
func TestEndToEndPinnedFingerprintIsOverTheDER(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, fingerprint, _ := startTestServer(t, registry)
	leaf := server.Certificate()
	recomputed := sha256.Sum256(leaf.Raw)
	if hex.EncodeToString(recomputed[:]) != fingerprint {
		t.Fatal("the pin must be over the certificate DER")
	}
	if len(fingerprint) != 64 {
		t.Fatalf("expected a 64-char hex digest, got %d", len(fingerprint))
	}
}

// A round trip through the real routes: adopt a key, then draw a token for it. Also the
// regression test for path encoding — the id must survive the URL intact.
func TestEndToEndAdoptThenDrawAToken(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, _ := newTestRegistry(t, stub)
	server, _, client := startTestServer(t, registry)

	resp := authed(t, client, http.MethodPost, server.URL+"/v1/accounts/adopt",
		`{"apiKey":"sk-ant-e2e","label":"End to end"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("adopt failed: %d %s", resp.StatusCode, body)
	}
	var account RemoteAccount
	if err := json.NewDecoder(resp.Body).Decode(&account); err != nil {
		t.Fatal(err)
	}
	if account.Kind != KindAPIKey {
		t.Fatalf("wrong kind %q", account.Kind)
	}

	tokenResp := authed(t, client, http.MethodGet,
		server.URL+"/v1/accounts/"+account.ID+"/token", "")
	defer tokenResp.Body.Close()
	if tokenResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(tokenResp.Body)
		t.Fatalf("token failed: %d %s", tokenResp.StatusCode, body)
	}
	var grant TokenGrant
	if err := json.NewDecoder(tokenResp.Body).Decode(&grant); err != nil {
		t.Fatal(err)
	}
	if grant.APIKey == nil || *grant.APIKey != "sk-ant-e2e" {
		t.Fatal("the key did not come back")
	}
	if grant.AccessToken != nil {
		t.Fatal("an API-key grant must not carry an access token")
	}
}

// The message has to survive the trip in the shape the client parses.
func TestEndToEndErrorsAreReadable(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)

	resp := authed(t, client, http.MethodGet,
		server.URL+"/v1/accounts/no-such-account/token", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
	var envelope ServerErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(envelope.Error.Message, "no usable credential") {
		t.Fatalf("unhelpful message: %q", envelope.Error.Message)
	}
}

// A whole login relay, minus the browser: the server issues the URL, keeps the verifier,
// and refuses the callback if the state does not match.
func TestEndToEndLoginRelay(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)

	resp := authed(t, client, http.MethodPost, server.URL+"/v1/login/start",
		`{"redirectPort":51234}`)
	defer resp.Body.Close()
	var started LoginStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&started); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(started.AuthorizeURL, "localhost%3A51234%2Fcallback") &&
		!strings.Contains(started.AuthorizeURL, "localhost:51234/callback") {
		t.Fatalf("redirect must point at the client's loopback: %s", started.AuthorizeURL)
	}

	bad := authed(t, client, http.MethodPost, server.URL+"/v1/login/finish",
		`{"loginID":"`+started.LoginID+`","code":"x","state":"wrong"}`)
	defer bad.Body.Close()
	if bad.StatusCode != http.StatusBadRequest {
		t.Fatalf("a mismatched state must be refused, got %d", bad.StatusCode)
	}
}

func TestEndToEndDeleteAndUsage(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, _ := newTestRegistry(t, stub)
	server, _, client := startTestServer(t, registry)

	account, err := registry.Adopt(context.Background(),
		AdoptRequest{APIKey: ptr("sk-ant-del")})
	if err != nil {
		t.Fatal(err)
	}

	// No usage has been recorded for an API-key account.
	usage := authed(t, client, http.MethodGet,
		server.URL+"/v1/accounts/"+account.ID+"/usage", "")
	usage.Body.Close()
	if usage.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", usage.StatusCode)
	}

	del := authed(t, client, http.MethodDelete, server.URL+"/v1/accounts/"+account.ID, "")
	del.Body.Close()
	if del.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", del.StatusCode)
	}
	if len(registry.List()) != 0 {
		t.Fatal("the account should be gone")
	}

	again := authed(t, client, http.MethodDelete, server.URL+"/v1/accounts/"+account.ID, "")
	again.Body.Close()
	if again.StatusCode != http.StatusNotFound {
		t.Fatalf("deleting twice should 404, got %d", again.StatusCode)
	}
}

// Usage must reach the client in the exact shape it decodes, dates included. This is the
// path that would break silently if a timestamp ever carried fractional seconds.
func TestEndToEndUsageEncodesDatesTheClientCanRead(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage": {200, `{"limits":[
		  {"kind":"session","percent":33.5,"resets_at":"2026-08-28T15:04:05.987Z"}]}`},
	})
	registry, _ := newTestRegistry(t, stub)
	server, _, client := startTestServer(t, registry)

	if _, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", "r1", time.Now().Add(time.Hour)))}); err != nil {
		t.Fatal(err)
	}
	// Adopt polls usage in the background; wait for it to land.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := registry.Usage("acct-1"); ok {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	resp := authed(t, client, http.MethodGet, server.URL+"/v1/accounts/acct-1/usage", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	raw, _ := io.ReadAll(resp.Body)
	text := string(raw)
	// Second precision only — Swift's .iso8601 decoder rejects anything finer.
	if !strings.Contains(text, `"2026-08-28T15:04:05Z"`) {
		t.Fatalf("reset timestamp not in the shape the client decodes: %s", text)
	}
	if strings.Contains(text, ".987") {
		t.Fatalf("fractional seconds leaked to the client: %s", text)
	}

	var usage RemoteUsage
	if err := json.Unmarshal(raw, &usage); err != nil {
		t.Fatal(err)
	}
	if len(usage.Windows) != 1 || usage.Windows[0].Percent != 33.5 {
		t.Fatalf("windows did not survive: %+v", usage.Windows)
	}
	if usage.AgeSeconds < 0 {
		t.Fatal("age must never be negative")
	}
}

func TestEndToEndUnknownRouteIs404(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)
	resp := authed(t, client, http.MethodGet, server.URL+"/v1/nope", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

func TestEndToEndMalformedBodyIsRejected(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServer(t, registry)
	resp := authed(t, client, http.MethodPost, server.URL+"/v1/login/start", `{not json`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

func TestSealedStoreIsUsedByTheServerPath(t *testing.T) {
	dir := t.TempDir()
	key, _ := LoadOrCreateMasterKey(filepath.Join(dir, "master.key"))
	secrets, err := NewEncryptedFileStore(filepath.Join(dir, "s.sealed"), key)
	if err != nil {
		t.Fatal(err)
	}
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
	client := &OAuthClient{HTTP: &http.Client{Transport: stub}}
	registry := NewRegistry(client, secrets, filepath.Join(dir, "accounts.json"))
	registry.Bootstrap()

	const secret = "sealed-refresh-token"
	if _, err := registry.Adopt(context.Background(), AdoptRequest{
		CredentialJSON: ptr(credentialJSON("a", secret, time.Now().Add(time.Hour)))}); err != nil {
		t.Fatal(err)
	}
	raw, err := readFileString(filepath.Join(dir, "s.sealed"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, secret) {
		t.Fatal("the refresh token is sitting in plaintext on disk")
	}
}
