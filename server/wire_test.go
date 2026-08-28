package main

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The client is Swift and decodes these with a synthesised Codable, so a renamed key or a
// reformatted date is a broken client rather than a compile error. These tests pin the
// wire format against Sources/CCMuxCore/Server/ServerProtocol.swift.

func TestTokenGrantKeysMatchTheSwiftClient(t *testing.T) {
	grant := TokenGrant{
		AccountID:        "acct-1",
		Kind:             KindSubscription,
		AccessToken:      ptr("token"),
		ExpiresIn:        ptr(3600.0),
		SubscriptionType: ptr("team"),
		RateLimitTier:    ptr("tier_x"),
		Scopes:           []string{"user:inference"},
	}
	encoded, err := json.Marshal(grant)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"accountID", "kind", "accessToken", "expiresIn",
		"subscriptionType", "rateLimitTier", "scopes"} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("missing key %q — the Swift client expects it", key)
		}
	}
	if len(decoded) != 7 {
		t.Errorf("unexpected keys on the wire: %v", decoded)
	}
}

func TestRemoteAccountKeysMatchTheSwiftClient(t *testing.T) {
	account := RemoteAccount{
		ID: "acct-1", Label: "One", Email: ptr("a@example.com"),
		OrganizationUUID: ptr("org"), OrganizationName: ptr("Org"),
		SubscriptionType: ptr("team"), RateLimitTier: ptr("tier"),
		Kind: KindSubscription, Health: HealthOK, HealthDetail: ptr("fine"),
		APIKeyFingerprint: ptr("abc"),
	}
	encoded, _ := json.Marshal(account)
	var decoded map[string]any
	_ = json.Unmarshal(encoded, &decoded)
	for _, key := range []string{"id", "label", "email", "organizationUUID",
		"organizationName", "subscriptionType", "rateLimitTier", "kind", "health",
		"healthDetail", "apiKeyFingerprint"} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("missing key %q", key)
		}
	}
}

// The single most breakable thing in the whole interop. Swift's `.iso8601` decoding
// strategy is ISO8601DateFormatter with only `.withInternetDateTime` — it rejects
// fractional seconds outright. Go's default time marshalling emits RFC3339Nano, so
// without the custom Time type every usage response with a sub-second reset timestamp
// would fail to decode on the client.
func TestDatesAreEmittedWithoutFractionalSeconds(t *testing.T) {
	instant := time.Date(2026, 8, 28, 12, 34, 56, 789_000_000, time.UTC)
	usage := RemoteUsage{
		AccountID: "acct-1",
		Windows: []UsageWindow{{
			Kind: WindowSession, Label: "5-hour", Percent: 42,
			ResetsAt: &Time{instant},
		}},
		AgeSeconds: 12,
	}
	encoded, err := json.Marshal(usage)
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	if !strings.Contains(text, `"2026-08-28T12:34:56Z"`) {
		t.Fatalf("expected a second-precision RFC3339 timestamp, got %s", text)
	}
	if regexp.MustCompile(`\d\d:\d\d:\d\d\.\d`).MatchString(text) {
		t.Fatalf("fractional seconds leaked into the wire format: %s", text)
	}
}

func TestUsageWindowKeysMatchTheSwiftClient(t *testing.T) {
	model := "Fable"
	window := UsageWindow{Kind: WindowWeeklyScoped, Label: "Weekly Fable", Percent: 10,
		ResetsAt: &Time{time.Now()}, ModelName: &model}
	encoded, _ := json.Marshal(window)
	var decoded map[string]any
	_ = json.Unmarshal(encoded, &decoded)
	for _, key := range []string{"kind", "label", "percent", "resetsAt", "modelName"} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("missing key %q", key)
		}
	}
	// `id`, `headroom` and friends are computed on the client and must not be sent.
	if len(decoded) != 5 {
		t.Errorf("unexpected keys on the wire: %v", decoded)
	}
}

// A nil reset must be absent or null, never the zero date — Swift would decode
// "0001-01-01T00:00:00Z" as a real timestamp in the year one.
func TestAnAbsentResetIsOmitted(t *testing.T) {
	encoded, _ := json.Marshal(UsageWindow{Kind: WindowSession, Label: "5-hour"})
	if strings.Contains(string(encoded), "0001-01-01") {
		t.Fatalf("zero date leaked: %s", encoded)
	}
	if strings.Contains(string(encoded), "resetsAt") {
		t.Fatalf("resetsAt should be omitted when unset: %s", encoded)
	}
}

func TestErrorEnvelopeIsNested(t *testing.T) {
	// The client decodes {"error":{"message":...}}; a flat string decodes to nothing and
	// it shows the raw JSON instead.
	encoded, _ := json.Marshal(ServerErrorResponse{
		Error: ServerErrorDetail{Message: "no usable credential for x"}})
	if string(encoded) != `{"error":{"message":"no usable credential for x"}}` {
		t.Fatalf("envelope changed shape: %s", encoded)
	}
}

func TestKindAndHealthRawValues(t *testing.T) {
	// These are Swift enum raw values; changing one silently breaks decoding.
	if string(KindSubscription) != "subscription" || string(KindAPIKey) != "apiKey" {
		t.Fatal("AccountKind raw values must match the Swift enum")
	}
	if string(HealthOK) != "ok" || string(HealthNeedsRelogin) != "needsRelogin" ||
		string(HealthUnknown) != "unknown" {
		t.Fatal("AccountHealth raw values must match the Swift enum")
	}
	for kind, want := range map[WindowKind]string{
		WindowSession: "session", WindowWeeklyAll: "weeklyAll",
		WindowWeeklyScoped: "weeklyScoped", WindowOther: "other",
	} {
		if string(kind) != want {
			t.Errorf("window kind %q should be %q", kind, want)
		}
	}
}

func TestIsUsable(t *testing.T) {
	cases := []struct {
		name  string
		grant TokenGrant
		want  bool
	}{
		{"live subscription", TokenGrant{Kind: KindSubscription,
			AccessToken: ptr("t"), ExpiresIn: ptr(3600.0)}, true},
		{"expired", TokenGrant{Kind: KindSubscription,
			AccessToken: ptr("t"), ExpiresIn: ptr(0.0)}, false},
		{"negative", TokenGrant{Kind: KindSubscription,
			AccessToken: ptr("t"), ExpiresIn: ptr(-30.0)}, false},
		{"unstated expiry", TokenGrant{Kind: KindSubscription, AccessToken: ptr("t")}, true},
		{"no token", TokenGrant{Kind: KindSubscription, ExpiresIn: ptr(3600.0)}, false},
		{"empty token", TokenGrant{Kind: KindSubscription,
			AccessToken: ptr(""), ExpiresIn: ptr(3600.0)}, false},
		{"api key", TokenGrant{Kind: KindAPIKey, APIKey: ptr("sk-ant-x")}, true},
		{"api key missing", TokenGrant{Kind: KindAPIKey}, false},
		{"api key empty", TokenGrant{Kind: KindAPIKey, APIKey: ptr("")}, false},
	}
	for _, tc := range cases {
		if got := tc.grant.IsUsable(); got != tc.want {
			t.Errorf("%s: IsUsable() = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// Round-trips the credential shape Claude Code writes, including unknown keys: a newer
// Claude Code may add fields, and dropping them degrades a credential the client later
// re-seeds into a session namespace.
func TestCredentialRoundTripsIncludingUnknownKeys(t *testing.T) {
	raw := `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r",
	  "expiresAt":1800000000000,"scopes":["user:inference"],
	  "subscriptionType":"team","rateLimitTier":"tier_x","somethingNew":{"x":1}}}`
	credential, ok := ParseCredential(raw)
	if !ok {
		t.Fatal("should have parsed")
	}
	if credential.AccessToken != "a" || credential.RefreshToken != "r" {
		t.Fatal("tokens did not survive")
	}
	if credential.SubscriptionType != "team" || credential.RateLimitTier != "tier_x" {
		t.Fatal("plan fields did not survive")
	}
	if credential.ExpiresAt.UnixMilli() != 1800000000000 {
		t.Fatalf("expiry did not survive: %v", credential.ExpiresAt)
	}

	again, ok := ParseCredential(credential.JSONString())
	if !ok {
		t.Fatal("re-parse failed")
	}
	if again.ExpiresAt.UnixMilli() != 1800000000000 {
		t.Fatal("expiry lost on round trip")
	}
	if !strings.Contains(credential.JSONString(), "somethingNew") {
		t.Fatal("unknown key was dropped on round trip")
	}
}

func TestCredentialWithoutAnAccessTokenIsRejected(t *testing.T) {
	for _, raw := range []string{
		`{"claudeAiOauth":{"refreshToken":"r"}}`,
		`{"claudeAiOauth":{"accessToken":""}}`,
		`{}`,
		`not json`,
	} {
		if _, ok := ParseCredential(raw); ok {
			t.Errorf("should have rejected %q", raw)
		}
	}
}

// The custom Time exists to *emit* second-precision RFC 3339, but it must also read back
// what it writes — and tolerate the fractional form Anthropic sends, since the same type
// is what a future decode path would use.
func TestTimeRoundTripsAndAcceptsBothSpellings(t *testing.T) {
	original := Time{time.Date(2026, 8, 28, 15, 4, 5, 0, time.UTC)}
	encoded, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Time
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !decoded.Equal(original.Time) {
		t.Fatalf("round trip changed the instant: %v -> %v", original.Time, decoded.Time)
	}

	// Fractional seconds, as the usage endpoint sends them.
	var fractional Time
	if err := json.Unmarshal([]byte(`"2026-08-28T15:04:05.987Z"`), &fractional); err != nil {
		t.Fatalf("should accept fractional seconds: %v", err)
	}
	if fractional.Second() != 5 {
		t.Fatalf("parsed wrong: %v", fractional.Time)
	}

	// And null must land as the zero value rather than an error.
	var empty Time
	if err := json.Unmarshal([]byte(`null`), &empty); err != nil || !empty.IsZero() {
		t.Fatalf("null should decode to zero, got %v %v", empty.Time, err)
	}

	var rubbish Time
	if err := json.Unmarshal([]byte(`"not a date"`), &rubbish); err == nil {
		t.Fatal("rubbish should fail to decode")
	}
}

// Go marshals a nil slice as `null`; Swift decodes these as non-optional arrays and
// throws on null. Three places can produce one, and all three are on paths a fresh server
// hits immediately: an account list before anything is adopted, a grant for an API-key
// account (no scopes), and usage with no windows recorded.
func TestEmptySlicesAreEmptyArraysNotNull(t *testing.T) {
	cases := map[string]any{
		"account list": AccountListResponse{APIVersion: apiVersion,
			Accounts: []RemoteAccount{}},
		"api key grant":    TokenGrant{AccountID: "a", Kind: KindAPIKey, APIKey: ptr("k"), Scopes: []string{}},
		"usage no windows": RemoteUsage{AccountID: "a", Windows: []UsageWindow{}},
	}
	for name, value := range cases {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if strings.Contains(string(encoded), "null") {
			t.Errorf("%s emitted null where Swift expects an array: %s", name, encoded)
		}
	}
}

// And the paths that build them must not reintroduce a nil. This is the guard that
// actually matters, because the structs above are only as safe as their constructors.
func TestServerBuiltResponsesNeverCarryNullSlices(t *testing.T) {
	stub := newStub(map[string]stubReply{"/v1/models": {200, `{"data":[]}`}})
	registry, _ := newTestRegistry(t, stub)

	// An empty account list, straight after bootstrap.
	encoded, _ := json.Marshal(AccountListResponse{APIVersion: apiVersion,
		Accounts: registry.List()})
	if strings.Contains(string(encoded), `"accounts":null`) {
		t.Fatalf("empty account list marshalled as null: %s", encoded)
	}

	// An API-key grant, which has no scopes.
	account, err := registry.Adopt(context.Background(), AdoptRequest{APIKey: ptr("sk-ant-nil")})
	if err != nil {
		t.Fatal(err)
	}
	grant, ok := registry.Token(context.Background(), account.ID)
	if !ok {
		t.Fatal("expected a grant")
	}
	encodedGrant, _ := json.Marshal(grant)
	if strings.Contains(string(encodedGrant), `"scopes":null`) {
		t.Fatalf("grant scopes marshalled as null: %s", encodedGrant)
	}

	// Usage recorded with no windows at all.
	registry.record(account.ID, nil, nil)
	usage, ok := registry.Usage(account.ID)
	if !ok {
		t.Fatal("expected usage")
	}
	encodedUsage, _ := json.Marshal(usage)
	if strings.Contains(string(encodedUsage), `"windows":null`) {
		t.Fatalf("usage windows marshalled as null: %s", encodedUsage)
	}
}
