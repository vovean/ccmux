package main

import (
	"encoding/json"
	"time"
)

// Credential is the payload Claude Code stores under `claudeAiOauth`, and the shape the
// Mac client sends in an AdoptRequest.
//
// Unknown keys round-trip: a newer Claude Code may add fields, and dropping them on the
// way through would quietly degrade a credential the client later re-seeds into a session
// namespace.
type Credential struct {
	AccessToken           string
	RefreshToken          string
	ExpiresAt             time.Time
	RefreshTokenExpiresAt time.Time
	Scopes                []string
	SubscriptionType      string
	RateLimitTier         string

	extra map[string]json.RawMessage
}

var knownCredentialKeys = map[string]bool{
	"accessToken": true, "refreshToken": true, "expiresAt": true,
	"refreshTokenExpiresAt": true, "scopes": true,
	"subscriptionType": true, "rateLimitTier": true,
}

// ParseCredential reads the `{"claudeAiOauth": {...}}` wrapper. Returns false when the
// payload has no usable access token, which is the same bar the Swift client applies.
func ParseCredential(raw string) (Credential, bool) {
	var root struct {
		OAuth map[string]json.RawMessage `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal([]byte(raw), &root); err != nil || root.OAuth == nil {
		return Credential{}, false
	}

	c := Credential{extra: map[string]json.RawMessage{}}
	str := func(key string) string {
		var s string
		if v, ok := root.OAuth[key]; ok {
			_ = json.Unmarshal(v, &s)
		}
		return s
	}
	// Milliseconds since the epoch, which is how Claude Code writes them.
	millis := func(key string) time.Time {
		var ms float64
		if v, ok := root.OAuth[key]; ok {
			if err := json.Unmarshal(v, &ms); err == nil && ms > 0 {
				return time.UnixMilli(int64(ms))
			}
		}
		return time.Time{}
	}

	c.AccessToken = str("accessToken")
	if c.AccessToken == "" {
		return Credential{}, false
	}
	c.RefreshToken = str("refreshToken")
	c.SubscriptionType = str("subscriptionType")
	c.RateLimitTier = str("rateLimitTier")
	c.ExpiresAt = millis("expiresAt")
	c.RefreshTokenExpiresAt = millis("refreshTokenExpiresAt")
	if v, ok := root.OAuth["scopes"]; ok {
		_ = json.Unmarshal(v, &c.Scopes)
	}
	for key, value := range root.OAuth {
		if !knownCredentialKeys[key] {
			c.extra[key] = value
		}
	}
	return c, true
}

func (c Credential) JSONString() string {
	oauth := map[string]any{}
	for key, value := range c.extra {
		oauth[key] = value
	}
	oauth["accessToken"] = c.AccessToken
	if c.RefreshToken != "" {
		oauth["refreshToken"] = c.RefreshToken
	}
	if !c.ExpiresAt.IsZero() {
		oauth["expiresAt"] = c.ExpiresAt.UnixMilli()
	}
	if !c.RefreshTokenExpiresAt.IsZero() {
		oauth["refreshTokenExpiresAt"] = c.RefreshTokenExpiresAt.UnixMilli()
	}
	if len(c.Scopes) > 0 {
		oauth["scopes"] = c.Scopes
	}
	if c.SubscriptionType != "" {
		oauth["subscriptionType"] = c.SubscriptionType
	}
	if c.RateLimitTier != "" {
		oauth["rateLimitTier"] = c.RateLimitTier
	}
	encoded, err := json.Marshal(map[string]any{"claudeAiOauth": oauth})
	if err != nil {
		return "{}"
	}
	return string(encoded)
}

// RemainingLife is how long the access token has left. Zero when there is no stated
// expiry, which callers treat as "unknown" rather than "expired".
func (c Credential) RemainingLife(now time.Time) (time.Duration, bool) {
	if c.ExpiresAt.IsZero() {
		return 0, false
	}
	return c.ExpiresAt.Sub(now), true
}
