package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The cross-language contract.
//
// These files are written by Go and decoded by Swift in
// Tests/CCMuxKitTests/ServerWireCompatibilityTests.swift, using the real CCMuxCore types
// and the real JSONStore.decoder. Nothing else checks that the two halves still agree:
// the client is a separate language with a separate model of the same protocol, so a
// renamed key or a reformatted date is a runtime failure on someone's Mac rather than a
// compile error anywhere.
//
// Regenerate with: UPDATE_FIXTURES=1 go test ./...
func TestWireFixturesMatchWhatWeEmit(t *testing.T) {
	reset := time.Date(2026, 8, 28, 15, 4, 5, 987_000_000, time.UTC)

	fixtures := map[string]any{
		"health.json": HealthResponse{
			APIVersion: apiVersion, Accounts: 2, UptimeSeconds: 1234.5,
		},
		"accounts.json": AccountListResponse{
			APIVersion: apiVersion,
			Accounts: []RemoteAccount{
				{
					ID: "11111111-2222-3333-4444-555555555555", Label: "Work",
					Email: ptr("someone@example.com"), OrganizationUUID: ptr("org-1"),
					OrganizationName: ptr("Example Org"), SubscriptionType: ptr("team"),
					RateLimitTier: ptr("tier_x"), Kind: KindSubscription, Health: HealthOK,
				},
				{
					ID: "local-uuid", Label: "Billing", Kind: KindAPIKey,
					Health: HealthNeedsRelogin, HealthDetail: ptr("no credential on the server"),
					APIKeyFingerprint: ptr(APIKeyFingerprint("sk-ant-fixture")),
				},
			},
		},
		"token-subscription.json": TokenGrant{
			AccountID: "11111111-2222-3333-4444-555555555555", Kind: KindSubscription,
			AccessToken: ptr("an-access-token"), ExpiresIn: ptr(3599.0),
			SubscriptionType: ptr("team"), RateLimitTier: ptr("tier_x"),
			Scopes: []string{"user:inference", "user:profile"},
		},
		"token-apikey.json": TokenGrant{
			AccountID: "local-uuid", Kind: KindAPIKey,
			APIKey: ptr("sk-ant-fixture"), Scopes: []string{},
		},
		"usage.json": RemoteUsage{
			AccountID: "11111111-2222-3333-4444-555555555555",
			Windows: []UsageWindow{
				{Kind: WindowSession, Label: "5-hour", Percent: 33.5, ResetsAt: &Time{reset}},
				{Kind: WindowWeeklyAll, Label: "Weekly", Percent: 12},
				{Kind: WindowWeeklyScoped, Label: "Weekly Fable", Percent: 61.25,
					ResetsAt: &Time{reset}, ModelName: ptr("Fable")},
			},
			AgeSeconds: 42.5,
		},
		"login-start.json": LoginStartResponse{
			LoginID:      "a-login-id",
			AuthorizeURL: "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A51234%2Fcallback",
			State:        "a-state-value",
		},
		"error.json": ServerErrorResponse{
			Error: ServerErrorDetail{Message: "no usable credential for acct-1"},
		},
	}

	dir := filepath.Join("testdata", "wire")
	update := os.Getenv("UPDATE_FIXTURES") == "1"
	if update {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	for name, value := range fixtures {
		encoded, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		encoded = append(encoded, '\n')
		path := filepath.Join(dir, name)

		if update {
			if err := os.WriteFile(path, encoded, 0o644); err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			continue
		}

		onDisk, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s missing — run UPDATE_FIXTURES=1 go test ./...: %v", name, err)
		}
		if string(onDisk) != string(encoded) {
			t.Errorf("%s has drifted from what the server emits.\n"+
				"The Swift client decodes this file; regenerate with "+
				"UPDATE_FIXTURES=1 go test ./... and check the Swift side still passes.\n"+
				"on disk:\n%s\nwould emit:\n%s", name, onDisk, encoded)
		}
	}
}
