package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Talks to the same OAuth and usage endpoints Claude Code uses. Ported from
// Sources/CCMuxCore/OAuth/OAuthClient.swift — the constants are what Claude Code itself
// sends, and the API rejects requests that do not look like it.
const (
	oauthClientID     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	oauthAuthorizeURL = "https://claude.com/cai/oauth/authorize"
	oauthTokenURL     = "https://platform.claude.com/v1/oauth/token"
	anthropicAPIBase  = "https://api.anthropic.com"
	anthropicBeta     = "oauth-2025-04-20"
)

var (
	loginScopes = []string{"org:create_api_key", "user:profile", "user:inference",
		"user:sessions:claude_code", "user:mcp_servers", "user:file_upload"}
	refreshScopes = []string{"user:profile", "user:inference",
		"user:sessions:claude_code", "user:mcp_servers", "user:file_upload"}
)

// OAuthError distinguishes a dead lineage from a bad afternoon. Only a permanent failure
// may mark an account as needing re-login; getting this wrong either hides a broken
// account or nags about a working one.
type OAuthError struct {
	Message   string
	Status    int
	Permanent bool
}

func (e *OAuthError) Error() string { return e.Message }

func permanentError(message string) *OAuthError {
	return &OAuthError{Message: message, Permanent: true}
}

func transientError(format string, args ...any) *OAuthError {
	return &OAuthError{Message: fmt.Sprintf(format, args...)}
}

type Identity struct {
	UUID             string
	Email            string
	OrganizationUUID string
	OrganizationName string
	SubscriptionType string
	RateLimitTier    string
}

// planName turns "claude_team" into "team". The profile spells it one way and the
// credential the other, and Claude Code reads the credential — a session seeded without
// this is treated as having no plan entitlement at all.
func planName(raw string) string {
	return strings.TrimPrefix(raw, "claude_")
}

type OAuthClient struct {
	HTTP *http.Client
}

func NewOAuthClient() *OAuthClient {
	return &OAuthClient{HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// PKCE stays on the server for the whole login, which is what makes the authorization
// code the browser hands back worthless to anyone who intercepts it.
type PKCE struct {
	Verifier  string
	Challenge string
	State     string
}

func NewPKCE() (PKCE, error) {
	verifier, err := randomURLSafe(64)
	if err != nil {
		return PKCE{}, err
	}
	state, err := randomURLSafe(32)
	if err != nil {
		return PKCE{}, err
	}
	sum := sha256.Sum256([]byte(verifier))
	return PKCE{
		Verifier:  verifier,
		Challenge: base64.RawURLEncoding.EncodeToString(sum[:]),
		State:     state,
	}, nil
}

func randomURLSafe(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// RedirectURI is always loopback, even though the credential is destined for this server:
// the browser doing the sign-in runs on the client, so the code lands there and is
// relayed. Measured 2026-08-27 — claude.com rewrites 127.0.0.1 to localhost, so this
// spelling is the one that survives.
func RedirectURI(port uint16) string {
	return fmt.Sprintf("http://localhost:%d/callback", port)
}

func AuthorizeURL(pkce PKCE, port uint16, loginHint string) string {
	q := url.Values{}
	q.Set("code", "true")
	q.Set("client_id", oauthClientID)
	q.Set("response_type", "code")
	q.Set("redirect_uri", RedirectURI(port))
	q.Set("scope", strings.Join(loginScopes, " "))
	q.Set("code_challenge", pkce.Challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("state", pkce.State)
	if loginHint != "" {
		q.Set("login_hint", loginHint)
	}
	return oauthAuthorizeURL + "?" + q.Encode()
}

func (c *OAuthClient) Exchange(ctx context.Context, rawCode string, pkce PKCE,
	port uint16) (Credential, error) {
	// The manual paste flow yields "code#state"; the loopback flow yields them
	// separately. Accept both so a pasted code still works.
	code, state := rawCode, pkce.State
	if idx := strings.Index(rawCode, "#"); idx >= 0 {
		code, state = rawCode[:idx], rawCode[idx+1:]
	}
	body := map[string]any{
		"grant_type":    "authorization_code",
		"code":          code,
		"redirect_uri":  RedirectURI(port),
		"client_id":     oauthClientID,
		"code_verifier": pkce.Verifier,
		"state":         state,
	}
	json, err := c.postJSON(ctx, oauthTokenURL, body)
	if err != nil {
		return Credential{}, err
	}
	return credentialFromTokenResponse(json, Credential{})
}

func (c *OAuthClient) Refresh(ctx context.Context, existing Credential) (Credential, error) {
	if existing.RefreshToken == "" {
		return Credential{}, permanentError("no refresh token stored")
	}
	body := map[string]any{
		"grant_type":    "refresh_token",
		"refresh_token": existing.RefreshToken,
		"client_id":     oauthClientID,
		"scope":         strings.Join(refreshScopes, " "),
	}
	json, err := c.postJSON(ctx, oauthTokenURL, body)
	if err != nil {
		return Credential{}, err
	}
	return credentialFromTokenResponse(json, existing)
}

func credentialFromTokenResponse(payload map[string]any, previous Credential) (Credential, error) {
	access, _ := payload["access_token"].(string)
	if access == "" {
		return Credential{}, &OAuthError{Message: "no access_token in token response"}
	}
	updated := previous
	if updated.extra == nil {
		updated.extra = map[string]json.RawMessage{}
	}
	updated.AccessToken = access
	if expiresIn, ok := payload["expires_in"].(float64); ok {
		updated.ExpiresAt = time.Now().Add(time.Duration(expiresIn) * time.Second)
	}
	if rotated, ok := payload["refresh_token"].(string); ok && rotated != "" {
		updated.RefreshToken = rotated
	}
	if scope, ok := payload["scope"].(string); ok {
		updated.Scopes = strings.Fields(scope)
	}
	// A refresh response does not restate the refresh token's own lifetime; keep the
	// previous value rather than implying an unknown expiry.
	return updated, nil
}

func (c *OAuthClient) Profile(ctx context.Context, accessToken string) (Identity, error) {
	payload, err := c.send(ctx, request{
		method: http.MethodGet,
		url:    anthropicAPIBase + "/api/oauth/profile",
		headers: map[string]string{
			"Authorization": "Bearer " + accessToken,
			"Content-Type":  "application/json",
		},
		timeout: 15 * time.Second,
	})
	if err != nil {
		return Identity{}, err
	}
	account, _ := payload["account"].(map[string]any)
	if account == nil {
		return Identity{}, &OAuthError{Message: "profile response has no account"}
	}
	uuid, _ := account["uuid"].(string)
	uuid = strings.TrimSpace(uuid)
	if uuid == "" {
		return Identity{}, &OAuthError{Message: "profile response has no account.uuid"}
	}
	email, _ := account["email"].(string)
	if email == "" {
		email, _ = account["email_address"].(string)
	}
	identity := Identity{UUID: uuid, Email: email}
	if org, ok := payload["organization"].(map[string]any); ok {
		identity.OrganizationUUID, _ = org["uuid"].(string)
		identity.OrganizationName, _ = org["name"].(string)
		orgType, _ := org["organization_type"].(string)
		identity.SubscriptionType = planName(orgType)
		identity.RateLimitTier, _ = org["rate_limit_tier"].(string)
	}
	return identity, nil
}

func (c *OAuthClient) Usage(ctx context.Context, accessToken string) ([]UsageWindow, error) {
	payload, err := c.send(ctx, request{
		method: http.MethodGet,
		url:    anthropicAPIBase + "/api/oauth/usage",
		headers: map[string]string{
			"Authorization":  "Bearer " + accessToken,
			"anthropic-beta": anthropicBeta,
		},
		timeout: 15 * time.Second,
	})
	if err != nil {
		return nil, err
	}
	return WindowsFromUsageResponse(payload), nil
}

// ValidateAPIKey confirms a key works. /v1/models costs nothing and answers 401 cleanly
// on a bad key, which makes it the right probe: verifying by sending a message would bill
// the user to find out they typed it wrong.
func (c *OAuthClient) ValidateAPIKey(ctx context.Context, key string) error {
	_, err := c.send(ctx, request{
		method: http.MethodGet,
		url:    anthropicAPIBase + "/v1/models",
		headers: map[string]string{
			"x-api-key":         key,
			"anthropic-version": "2023-06-01",
		},
		timeout: 20 * time.Second,
	})
	return err
}

type request struct {
	method  string
	url     string
	headers map[string]string
	body    []byte
	timeout time.Duration
}

func (c *OAuthClient) postJSON(ctx context.Context, target string,
	body map[string]any) (map[string]any, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return c.send(ctx, request{
		method:  http.MethodPost,
		url:     target,
		headers: map[string]string{"Content-Type": "application/json"},
		body:    encoded,
		timeout: 30 * time.Second,
	})
}

func (c *OAuthClient) send(ctx context.Context, spec request) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, spec.timeout)
	defer cancel()

	var reader io.Reader
	if spec.body != nil {
		reader = bytes.NewReader(spec.body)
	}
	req, err := http.NewRequestWithContext(ctx, spec.method, spec.url, reader)
	if err != nil {
		return nil, transientError("could not build request: %v", err)
	}
	for name, value := range spec.headers {
		req.Header.Set(name, value)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, transientError("network: %v", err)
	}
	defer resp.Body.Close()
	// Capped so a wedged upstream cannot exhaust memory on a 961 MB box.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, transientError("network: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		text := string(raw)
		if len(text) > 600 {
			text = text[:600]
		}
		switch resp.StatusCode {
		case 400, 401, 403:
			if strings.Contains(text, "invalid_grant") || strings.Contains(text, "invalid_client") {
				return nil, &OAuthError{
					Message:   "sign-in expired: " + text,
					Status:    resp.StatusCode,
					Permanent: true,
				}
			}
		}
		// Prefer the API's own message: this text reaches the user in the adopt failure
		// toast, and a raw response body is not an explanation. Swift extracted it too.
		message := fmt.Sprintf("HTTP %d: %s", resp.StatusCode, text)
		var envelope struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &envelope) == nil && envelope.Error.Message != "" {
			// Truncated like `text`: this reaches a 400 body and snapshot.LastError, and
			// the cap above applies to the raw body, not to what we pull out of it.
			message = envelope.Error.Message
			if len(message) > 600 {
				message = message[:600]
			}
		}
		return nil, &OAuthError{Message: message, Status: resp.StatusCode}
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, &OAuthError{Message: "body was not a JSON object"}
	}
	return payload, nil
}

// IsPermanent reports whether a failure means the lineage is dead. Anything else is a bad
// afternoon and must not mark the account.
func IsPermanent(err error) bool {
	var oauthErr *OAuthError
	if errors.As(err, &oauthErr) {
		return oauthErr.Permanent
	}
	return false
}

func statusOf(err error) int {
	var oauthErr *OAuthError
	if errors.As(err, &oauthErr) {
		return oauthErr.Status
	}
	return 0
}
