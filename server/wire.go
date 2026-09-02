package main

import (
	"encoding/json"
	"strings"
	"time"
)

// The ccmuxd wire types. These must match Sources/CCMuxCore/Server/ServerProtocol.swift
// field for field: the Mac client decodes them with Swift's synthesised Codable, so a
// renamed key is a broken client, not a compile error.
//
// The shape is decided by one rule: a refresh token never appears in a response. The
// server is the sole holder of every lineage, so it hands out access tokens — which
// expire on their own — and nothing that could rotate a lineage behind its back. Adopt is
// the single exception and goes the other way, client to server.

const (
	apiPrefix = "/v1"
	// Bumped when a change would make an older client misread a response. Adding a route
	// or an optional field does not qualify: the client refuses to talk to a server whose
	// version differs from its own, so a bump strands every Mac that has not upgraded yet.
	apiVersion = 1
)

// What this build can do beyond the original surface. A client that finds its feature
// missing — an older ccmuxd, which omits the field entirely — turns the feature off and
// says why, instead of showing errors from routes that answer 404.
const featureSessions = "sessions"
const featureHooks = "hooks"
const featureHookActivation = "hook-activation"

var serverFeatures = []string{featureSessions, featureHooks, featureHookActivation}

// Time marshals as RFC 3339 with second precision.
//
// Load-bearing: the client decodes with Swift's `.iso8601` strategy, which is
// ISO8601DateFormatter with only `.withInternetDateTime` — it *rejects* fractional
// seconds. Go's default time marshalling emits RFC3339Nano, which would make every
// usage response fail to decode the moment a reset timestamp had a non-zero nanosecond.
type Time struct{ time.Time }

func (t Time) MarshalJSON() ([]byte, error) {
	if t.IsZero() {
		return []byte("null"), nil
	}
	return json.Marshal(t.UTC().Truncate(time.Second).Format(time.RFC3339))
}

func (t *Time) UnmarshalJSON(data []byte) error {
	s := strings.Trim(string(data), `"`)
	if s == "null" || s == "" {
		t.Time = time.Time{}
		return nil
	}
	// Accept both spellings: Anthropic sends fractional seconds, our own files do not.
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, s); err == nil {
			t.Time = parsed
			return nil
		}
	}
	return &time.ParseError{Layout: time.RFC3339, Value: s}
}

type AccountKind string

const (
	KindSubscription AccountKind = "subscription"
	KindAPIKey       AccountKind = "apiKey"
)

type AccountHealth string

const (
	HealthOK           AccountHealth = "ok"
	HealthNeedsRelogin AccountHealth = "needsRelogin"
	HealthUnknown      AccountHealth = "unknown"
)

// RemoteAccount is an account as the server describes it. Deliberately not the client's
// own Account: that carries per-machine concerns (priority, Chrome profile, rotation,
// spend) which have no business being centralised.
type RemoteAccount struct {
	ID               string        `json:"id"`
	Label            string        `json:"label"`
	Email            *string       `json:"email,omitempty"`
	OrganizationUUID *string       `json:"organizationUUID,omitempty"`
	OrganizationName *string       `json:"organizationName,omitempty"`
	SubscriptionType *string       `json:"subscriptionType,omitempty"`
	RateLimitTier    *string       `json:"rateLimitTier,omitempty"`
	Kind             AccountKind   `json:"kind"`
	Health           AccountHealth `json:"health"`
	HealthDetail     *string       `json:"healthDetail,omitempty"`
	// SHA-256 of the API key. An API-key account's id is a locally generated UUID and so
	// differs on every machine; this is the only thing that can match one across two.
	APIKeyFingerprint *string `json:"apiKeyFingerprint,omitempty"`
}

func (a RemoteAccount) DisplayName() string {
	if a.Label != "" {
		return a.Label
	}
	if a.Email != nil && *a.Email != "" {
		return *a.Email
	}
	return a.ID
}

// TokenGrant is one access token, plus what Claude Code needs stamped into a seeded
// namespace.
//
// ExpiresIn is seconds, not an absolute date, on purpose: the server and a laptop do not
// agree on the wall clock, and a client that trusted a remote timestamp would treat
// tokens as fresh that the API considers dead.
type TokenGrant struct {
	AccountID        string      `json:"accountID"`
	Kind             AccountKind `json:"kind"`
	AccessToken      *string     `json:"accessToken,omitempty"`
	APIKey           *string     `json:"apiKey,omitempty"`
	ExpiresIn        *float64    `json:"expiresIn,omitempty"`
	SubscriptionType *string     `json:"subscriptionType,omitempty"`
	RateLimitTier    *string     `json:"rateLimitTier,omitempty"`
	Scopes           []string    `json:"scopes"`
}

// IsUsable mirrors the client's own check. A non-nil access token is not enough: the
// server returns what it holds even when a refresh failed, so a grant can carry a token
// that expired minutes ago.
func (g TokenGrant) IsUsable() bool {
	switch g.Kind {
	case KindAPIKey:
		return g.APIKey != nil && *g.APIKey != ""
	default:
		if g.AccessToken == nil || *g.AccessToken == "" {
			return false
		}
		if g.ExpiresIn == nil {
			return true
		}
		return *g.ExpiresIn > 0
	}
}

type RemoteUsage struct {
	AccountID string        `json:"accountID"`
	Windows   []UsageWindow `json:"windows"`
	// How stale the server's snapshot is, in seconds. Same reasoning as ExpiresIn.
	AgeSeconds float64 `json:"ageSeconds"`
}

type LoginStartRequest struct {
	// The port the client's own loopback listener is on. The redirect stays on localhost:
	// the browser runs on the client, so the code lands there and is relayed back.
	RedirectPort uint16  `json:"redirectPort"`
	AccountID    *string `json:"accountID,omitempty"`
	LoginHint    *string `json:"loginHint,omitempty"`
}

type LoginStartResponse struct {
	LoginID      string `json:"loginID"`
	AuthorizeURL string `json:"authorizeURL"`
	// Echoed so the client can check the browser's state before relaying the code.
	State string `json:"state"`
}

type LoginFinishRequest struct {
	LoginID string  `json:"loginID"`
	Code    string  `json:"code"`
	State   *string `json:"state,omitempty"`
}

// AdoptRequest is a client handing a credential it already holds up to the server. The
// one direction in which a refresh token crosses the wire, which is why the client never
// does it without being told to, account by account.
type AdoptRequest struct {
	CredentialJSON *string `json:"credentialJSON,omitempty"`
	APIKey         *string `json:"apiKey,omitempty"`
	Label          *string `json:"label,omitempty"`
}

type AccountListResponse struct {
	APIVersion int             `json:"apiVersion"`
	Accounts   []RemoteAccount `json:"accounts"`
}

type HealthResponse struct {
	APIVersion    int      `json:"apiVersion"`
	Accounts      int      `json:"accounts"`
	UptimeSeconds float64  `json:"uptimeSeconds"`
	Features      []string `json:"features"`
	// Machines that have reported sessions recently. Only ever a diagnostic — the count
	// says whether reporting is reaching the server at all.
	Machines int `json:"machines"`
}

// MachineSession is one session as the Mac running it describes it.
//
// No pid and no port: they are meaningless on another host, and leaving them out is what
// keeps a foreign card from ever growing a control that would act on the wrong process.
//
// Every time here is an age in seconds rather than a timestamp. Three clocks are involved
// — two laptops and a VPS — so the client adds the reporting machine's own staleness to
// these to get a real age, and no absolute time ever crosses a machine boundary.
type MachineSession struct {
	ID        string `json:"id"`
	AccountID string `json:"accountID"`
	// SHA-256 of the API key when the account is one. Such an account's id is generated
	// by whichever Mac added it, so this is the only thing that matches one across two.
	AccountFingerprint *string `json:"accountFingerprint,omitempty"`
	// Carried so a session for an account this Mac has never seen still has a name to be
	// grouped under, rather than eight characters of UUID.
	AccountLabel string  `json:"accountLabel"`
	Name         string  `json:"name"`
	Directory    *string `json:"directory,omitempty"`
	Policy       string  `json:"policy"`
	// "busy", "waiting", "idle", or empty when Claude Code has not said.
	Status            string   `json:"status"`
	StartedSecondsAgo float64  `json:"startedSecondsAgo"`
	UpdatedSecondsAgo *float64 `json:"updatedSecondsAgo,omitempty"`
	SpendUSD          float64  `json:"spendUSD"`
}

// MachineReport is one Mac's entire session list. The machine id comes from the path, so
// there is exactly one authority on which machine a report belongs to.
type MachineReport struct {
	Label    string           `json:"label"`
	Sessions []MachineSession `json:"sessions"`
}

type MachineSnapshot struct {
	MachineID string           `json:"machineID"`
	Label     string           `json:"label"`
	Sessions  []MachineSession `json:"sessions"`
	// Since this machine last reported. Added to each session's own age by the client,
	// and on its own it is what decides whether the machine is shown as current, shown
	// as stale, or not shown at all.
	AgeSeconds float64 `json:"ageSeconds"`
}

type SessionsResponse struct {
	APIVersion int               `json:"apiVersion"`
	Machines   []MachineSnapshot `json:"machines"`
}

// ServerErrorResponse is the envelope the client parses. Nested, because that is the
// shape Hummingbird emitted and the client was written against it — a flat
// {"error":"..."} decodes to nothing and the user sees raw JSON.
type ServerErrorResponse struct {
	Error ServerErrorDetail `json:"error"`
}

type ServerErrorDetail struct {
	Message string `json:"message"`
}

func ptr[T any](v T) *T { return &v }

// One file ccmux writes under ~/.claude/hooks/managed on every Mac. Content is carried
// inline rather than by reference: a hook set is small, and a URL would be a second thing
// to authenticate and a second thing to be unreachable when a laptop changes network.
type HookFile struct {
	Path       string `json:"path"`
	Content    string `json:"content"`
	Executable bool   `json:"executable"`
	// Whether a Mac should register this script with Claude Code, as opposed to merely
	// holding it on disk. A pointer so a bundle written before this field existed keeps
	// its hooks registered instead of silently unregistering them on every Mac; absent
	// means active. Never part of hookVersion — that hash is compared against what is on
	// disk, and activation is not a property of the file.
	Active *bool `json:"active,omitempty"`
}

// IsActive reports whether this script should be registered. Absent means yes.
func (f HookFile) IsActive() bool { return f.Active == nil || *f.Active }

// The whole hook set, with a content hash so a client can tell in one field whether it
// has anything to do.
type HookBundle struct {
	APIVersion int        `json:"apiVersion"`
	Version    string     `json:"version"`
	UpdatedAt  Time       `json:"updatedAt"`
	Files      []HookFile `json:"files"`
}

type HookPushRequest struct {
	Files []HookFile `json:"files"`
}

// HookActivationRequest flips one script's registration.
//
// A dedicated route rather than a whole-bundle PUT: activation is the operation a user
// repeats, and a read-modify-write of the whole bundle would drop a script another Mac
// published in between. The server flips the flag under its own lock.
type HookActivationRequest struct {
	Path   string `json:"path"`
	Active bool   `json:"active"`
}
