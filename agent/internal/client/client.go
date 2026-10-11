// Package client talks to ccmuxd.
//
// Trust is a pinned certificate, not a CA: ccmuxd serves a self-signed certificate, so
// the SHA-256 of its leaf is the whole of the decision — the same rule, over the same
// bytes, as the Mac client's Security.framework check.
package client

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"ccmuxagent/internal/config"
	"ccmuxd/wire"
)

// ErrNoCredential is the token route's 404: the server holds no usable credential for
// this account. Its lineage is dead and only a fresh sign-in recovers it — which is a
// different thing from the server being unreachable, and the two must never be
// conflated, or an outage would mark every account as needing re-login.
var ErrNoCredential = errors.New("the account server has no working credential")

// StatusError is a refusal the server explained. Anything else is a transport error.
type StatusError struct {
	Status  int
	Message string
}

func (e *StatusError) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("ccmuxd answered %d", e.Status)
	}
	return e.Message
}

// Transient reports whether retrying later could plausibly work. A refusal of the
// request itself will not fix itself; 429 and 5xx might.
func (e *StatusError) Transient() bool {
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

type Client struct {
	base       *url.URL
	username   string
	password   string
	httpClient *http.Client
}

const (
	// Long enough for a token refresh the server has to make upstream.
	requestTimeout = 30 * time.Second
	maxBody        = 8 << 20
)

func New(cfg config.Config, password string) (*Client, error) {
	base, err := url.Parse(strings.TrimSuffix(cfg.Server.URL, "/"))
	if err != nil {
		return nil, fmt.Errorf("server url %q is not a url: %w", cfg.Server.URL, err)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if !cfg.Server.Insecure {
		pin, err := hex.DecodeString(strings.ToLower(cfg.Server.Pin))
		if err != nil || len(pin) != sha256.Size {
			return nil, fmt.Errorf("pin must be 64 hex characters")
		}
		transport.TLSClientConfig = &tls.Config{
			// The pin replaces chain validation; it does not skip it.
			InsecureSkipVerify:    true,
			VerifyPeerCertificate: verifyPin(pin),
		}
	}
	return &Client{
		base:       base,
		username:   cfg.Server.Username,
		password:   password,
		httpClient: &http.Client{Timeout: requestTimeout, Transport: transport},
	}, nil
}

func verifyPin(pin []byte) func([][]byte, [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
		if len(rawCerts) == 0 {
			return errors.New("ccmuxd presented no certificate")
		}
		sum := sha256.Sum256(rawCerts[0])
		if subtle.ConstantTimeCompare(sum[:], pin) != 1 {
			return fmt.Errorf("ccmuxd's certificate is %s, which is not the pinned one — "+
				"either the certificate was replaced or this is not ccmuxd",
				hex.EncodeToString(sum[:]))
		}
		return nil
	}
}

func (c *Client) Health(ctx context.Context) (wire.HealthResponse, error) {
	var out wire.HealthResponse
	err := c.do(ctx, http.MethodGet, nil, &out, "health")
	return out, err
}

// Supports reports whether this server advertises a named capability. A client that
// finds its feature missing turns it off and says why, rather than showing errors from
// routes that answer 404.
func Supports(health wire.HealthResponse, feature string) bool {
	for _, advertised := range health.Features {
		if advertised == feature {
			return true
		}
	}
	return false
}

func (c *Client) Accounts(ctx context.Context) ([]wire.RemoteAccount, error) {
	var out wire.AccountListResponse
	if err := c.do(ctx, http.MethodGet, nil, &out, "accounts"); err != nil {
		return nil, err
	}
	return out.Accounts, nil
}

func (c *Client) Groups(ctx context.Context) ([]wire.SubscriptionGroup, error) {
	var out wire.GroupListResponse
	if err := c.do(ctx, http.MethodGet, nil, &out, "groups"); err != nil {
		return nil, err
	}
	return out.Groups, nil
}

func (c *Client) Usage(ctx context.Context, accountID string) (wire.RemoteUsage, error) {
	var out wire.RemoteUsage
	err := c.do(ctx, http.MethodGet, nil, &out, "accounts", accountID, "usage")
	return out, err
}

// Token draws one access token. A 404 means the lineage is dead, which is reported as
// ErrNoCredential so a caller can tell it from the server being down.
func (c *Client) Token(ctx context.Context, accountID string) (wire.TokenGrant, error) {
	var out wire.TokenGrant
	err := c.do(ctx, http.MethodGet, nil, &out, "accounts", accountID, "token")
	var status *StatusError
	if errors.As(err, &status) && status.Status == http.StatusNotFound {
		return wire.TokenGrant{}, fmt.Errorf("%w: %s", ErrNoCredential, status.Message)
	}
	return out, err
}

func (c *Client) ReportSessions(ctx context.Context, machineID string,
	report wire.MachineReport) (wire.SessionsResponse, error) {
	var out wire.SessionsResponse
	err := c.do(ctx, http.MethodPost, report, &out, "machines", machineID, "sessions")
	return out, err
}

func (c *Client) ReportUsage(ctx context.Context, machineID string,
	report wire.UsageReport) (wire.UsageIngestResponse, error) {
	var out wire.UsageIngestResponse
	err := c.do(ctx, http.MethodPost, report, &out, "machines", machineID, "usage")
	return out, err
}

func checkVersion(version int) error {
	if version != 0 && version != wire.APIVersion {
		return fmt.Errorf("this ccmuxd speaks api version %d and the agent speaks %d — "+
			"upgrade whichever is older", version, wire.APIVersion)
	}
	return nil
}

func (c *Client) do(ctx context.Context, method string, body any, into any,
	segments ...string) error {
	// Both halves are set by hand. Assigning only Path escapes the segments a second
	// time, and JoinPath resolves `..` as path syntax — so an id containing one would
	// address a different route entirely.
	target := *c.base
	plain := strings.TrimSuffix(target.Path, "/") + wire.APIPrefix
	escaped := plain
	for _, segment := range segments {
		plain += "/" + segment
		escaped += "/" + url.PathEscape(segment)
	}
	target.Path, target.RawPath = plain, escaped

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("could not encode request: %w", err)
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, target.String(), reader)
	if err != nil {
		return err
	}
	request.SetBasicAuth(c.username, c.password)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, maxBody))
	if err != nil {
		return err
	}
	if response.StatusCode >= 300 {
		return &StatusError{Status: response.StatusCode, Message: message(payload, response)}
	}
	if into == nil {
		return nil
	}
	if err := json.Unmarshal(payload, into); err != nil {
		return fmt.Errorf("could not decode ccmuxd's answer: %w", err)
	}
	// Checked here rather than per route: a bump means an older client would misread the
	// answer, and an agent that only draws tokens and posts usage never calls a route
	// that would otherwise notice.
	var versioned struct {
		APIVersion int `json:"apiVersion"`
	}
	if json.Unmarshal(payload, &versioned) == nil {
		return checkVersion(versioned.APIVersion)
	}
	return nil
}

// The server's envelope is nested; a body that is not one at all (a proxy's error page,
// say) still has to produce something a person can act on.
func message(payload []byte, response *http.Response) string {
	var envelope wire.ServerErrorResponse
	if err := json.Unmarshal(payload, &envelope); err == nil && envelope.Error.Message != "" {
		return envelope.Error.Message
	}
	if response.StatusCode == http.StatusUnauthorized {
		return "ccmuxd refused the password"
	}
	text := strings.TrimSpace(string(payload))
	if len(text) > 200 {
		text = text[:200] + "…"
	}
	if text == "" {
		return fmt.Sprintf("ccmuxd answered %d", response.StatusCode)
	}
	return fmt.Sprintf("ccmuxd answered %d: %s", response.StatusCode, text)
}
