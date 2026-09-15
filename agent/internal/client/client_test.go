package client

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"ccmuxagent/internal/config"
	"ccmuxd/wire"
)

type recorded struct {
	path    string
	rawPath string
	user    string
	pass    string
	ok      bool
	body    []byte
}

func serve(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *recorded) {
	t.Helper()
	seen := &recorded{}
	server := httptest.NewTLSServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			seen.path = r.URL.Path
			seen.rawPath = r.URL.EscapedPath()
			seen.user, seen.pass, seen.ok = r.BasicAuth()
			if r.Body != nil {
				buf := make([]byte, 1<<16)
				n, _ := r.Body.Read(buf)
				seen.body = buf[:n]
			}
			handler(w, r)
		}))
	t.Cleanup(server.Close)
	return server, seen
}

func pinOf(server *httptest.Server) string {
	sum := sha256.Sum256(server.Certificate().Raw)
	return hex.EncodeToString(sum[:])
}

func clientFor(t *testing.T, server *httptest.Server, pin string) *Client {
	t.Helper()
	cfg := config.Defaults()
	cfg.Server.URL = server.URL
	cfg.Server.Username = "ccmux"
	cfg.Server.Pin = pin
	client, err := New(cfg, "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func json200(payload any) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(payload)
	}
}

func TestAPinnedCertificateIsAccepted(t *testing.T) {
	server, seen := serve(t, json200(wire.AccountListResponse{
		APIVersion: wire.APIVersion,
		Accounts:   []wire.RemoteAccount{{ID: "acct-1", Label: "Work", Kind: wire.KindSubscription}},
	}))
	accounts, err := clientFor(t, server, pinOf(server)).Accounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 || accounts[0].ID != "acct-1" {
		t.Fatalf("got %+v", accounts)
	}
	if seen.path != "/v1/accounts" {
		t.Errorf("path %q", seen.path)
	}
	if !seen.ok || seen.user != "ccmux" || seen.pass != "hunter2" {
		t.Errorf("basic auth not sent: %v %q", seen.ok, seen.user)
	}
}

// The pin is the entire trust decision, so the wrong one has to fail the handshake —
// not merely warn.
func TestACertificateOutsideThePinIsRefused(t *testing.T) {
	server, _ := serve(t, json200(wire.AccountListResponse{APIVersion: wire.APIVersion}))
	wrong := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	_, err := clientFor(t, server, wrong).Accounts(context.Background())
	if err == nil {
		t.Fatal("an unpinned certificate was accepted")
	}
}

// An account id is a path segment and arrives from the server's own list, but it is
// still interpolated into a URL.
func TestAnAccountIDIsEscapedIntoThePath(t *testing.T) {
	server, seen := serve(t, json200(wire.RemoteUsage{AccountID: "x"}))
	_, err := clientFor(t, server, pinOf(server)).Usage(context.Background(), "a/../b")
	if err != nil {
		t.Fatal(err)
	}
	// One layer of escaping, not two: the server decodes this back to the id we meant.
	if seen.path != "/v1/accounts/a/../b/usage" {
		t.Fatalf("path not escaped correctly: %q", seen.path)
	}
	if seen.rawPath != "/v1/accounts/a%2F..%2Fb/usage" {
		t.Fatalf("raw path %q", seen.rawPath)
	}
}

func TestADeadLineageIsDistinctFromAnOutage(t *testing.T) {
	server, _ := serve(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(wire.ServerErrorResponse{
			Error: wire.ServerErrorDetail{Message: "no usable credential for acct-1"}})
	})
	_, err := clientFor(t, server, pinOf(server)).Token(context.Background(), "acct-1")
	if !errors.Is(err, ErrNoCredential) {
		t.Fatalf("got %v, want ErrNoCredential", err)
	}
	if got := err.Error(); got == "" || !strings.Contains(got, "no usable credential") {
		t.Errorf("the server's reason was lost: %q", got)
	}
}

func TestATransientRefusalSaysSo(t *testing.T) {
	server, _ := serve(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(w).Encode(wire.ServerErrorResponse{
			Error: wire.ServerErrorDetail{Message: "could not write the report"}})
	})
	_, err := clientFor(t, server, pinOf(server)).ReportUsage(
		context.Background(), "m1", wire.UsageReport{Label: "box"})
	var status *StatusError
	if !errors.As(err, &status) {
		t.Fatalf("got %v, want a StatusError", err)
	}
	if !status.Transient() {
		t.Error("503 should be transient — the spool is kept and re-sent")
	}
	if status.Message != "could not write the report" {
		t.Errorf("envelope not decoded: %q", status.Message)
	}
}

// A version the agent cannot read has to be refused rather than half-decoded: the Mac
// client refuses the same way.
func TestAnApiVersionMismatchIsRefused(t *testing.T) {
	server, _ := serve(t, json200(wire.AccountListResponse{APIVersion: wire.APIVersion + 1}))
	if _, err := clientFor(t, server, pinOf(server)).Accounts(context.Background()); err == nil {
		t.Fatal("a newer api version was accepted")
	}
}

func TestAWrongPasswordIsReportedPlainly(t *testing.T) {
	server, _ := serve(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("WWW-Authenticate", `Basic realm="ccmuxd"`)
		w.WriteHeader(http.StatusUnauthorized)
	})
	_, err := clientFor(t, server, pinOf(server)).Health(context.Background())
	if err == nil || !strings.Contains(err.Error(), "refused the password") {
		t.Fatalf("got %v", err)
	}
}
