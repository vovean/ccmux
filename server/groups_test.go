package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func adoptSubscription(t *testing.T, registry *Registry, req AdoptRequest) RemoteAccount {
	t.Helper()
	req.CredentialJSON = ptr(credentialJSON("access", "refresh", time.Now().Add(time.Hour)))
	account, err := registry.Adopt(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return account
}

func subscriptionStub() *stubTransport {
	return newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
	})
}

func TestGroupsSurviveARestartAndOneNameIsOneGroup(t *testing.T) {
	registry, secrets := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})

	first, err := registry.CreateGroup("  Cossacks ")
	if err != nil {
		t.Fatal(err)
	}
	again, err := registry.CreateGroup("cossacks")
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != first.ID || first.Name != "Cossacks" {
		t.Fatalf("a second create of the same name must answer with the first group: %+v %+v",
			first, again)
	}
	if _, err := registry.UpdateAccount(account.ID,
		AccountUpdate{GroupID: ptr(first.ID)}); err != nil {
		t.Fatal(err)
	}

	restarted := NewRegistry(registry.client, secrets, registry.accountsFile)
	restarted.Bootstrap()
	groups, err := restarted.Groups()
	if err != nil || len(groups) != 1 || groups[0] != first {
		t.Fatalf("groups did not survive a restart: %v %v", groups, err)
	}
	if restarted.List()[0].Group() != first.ID {
		t.Fatal("membership did not survive a restart")
	}
}

func TestDeletingAGroupLeavesItsAccountsUngrouped(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})
	group, _ := registry.CreateGroup("Project")
	_, _ = registry.UpdateAccount(account.ID, AccountUpdate{GroupID: ptr(group.ID)})

	if err := registry.DeleteGroup(group.ID); err != nil {
		t.Fatal(err)
	}
	if registry.List()[0].GroupID != nil {
		t.Fatal("an account kept pointing at a deleted group")
	}
	if err := registry.DeleteGroup(group.ID); err == nil {
		t.Fatal("deleting an unknown group must fail")
	}
}

func TestMovingAnAccountTakesItOutOfItsOldGroup(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})
	a, _ := registry.CreateGroup("A")
	b, _ := registry.CreateGroup("B")
	_, _ = registry.UpdateAccount(account.ID, AccountUpdate{GroupID: ptr(a.ID)})
	moved, err := registry.UpdateAccount(account.ID, AccountUpdate{GroupID: ptr(b.ID)})
	if err != nil || moved.Group() != b.ID {
		t.Fatalf("move failed: %+v %v", moved, err)
	}
	cleared, _ := registry.UpdateAccount(account.ID, AccountUpdate{GroupID: ptr("")})
	if cleared.GroupID != nil {
		t.Fatal("an empty group id must ungroup the account")
	}
}

func TestAnAccountUpdateWithAnUnknownGroupChangesNothing(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})
	_, err := registry.UpdateAccount(account.ID, AccountUpdate{
		Label: ptr("renamed"), InRotation: ptr(false), GroupID: ptr("no-such-group")})
	if err == nil {
		t.Fatal("an unknown group must be refused")
	}
	after := registry.List()[0]
	if after.Label != account.Label || !after.IsInRotation() {
		t.Fatalf("a refused update applied some of its fields: %+v", after)
	}
}

func TestSharedSettingsAreStoredAndABudgetOfZeroClearsIt(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})
	if !account.IsInRotation() {
		t.Fatal("an account nobody has touched is in rotation")
	}
	updated, err := registry.UpdateAccount(account.ID, AccountUpdate{
		Label: ptr(" Work "), InRotation: ptr(false), MonthlyBudgetUSD: ptr(50.0)})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Label != "Work" || updated.IsInRotation() || *updated.MonthlyBudgetUSD != 50 {
		t.Fatalf("settings not applied: %+v", updated)
	}
	cleared, _ := registry.UpdateAccount(account.ID, AccountUpdate{MonthlyBudgetUSD: ptr(0.0)})
	if cleared.MonthlyBudgetUSD != nil || cleared.IsInRotation() {
		t.Fatalf("a zero budget must clear only the budget: %+v", cleared)
	}
}

// An upload re-attaching a lineage to an account the server already has must not undo
// what other machines set since.
func TestAdoptCarriesSettingsOnlyWhenItCreatesTheAccount(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	created := adoptSubscription(t, registry, AdoptRequest{
		InRotation: ptr(false), MonthlyBudgetUSD: ptr(20.0)})
	if created.IsInRotation() || *created.MonthlyBudgetUSD != 20 {
		t.Fatalf("a new account must take the settings it was uploaded with: %+v", created)
	}
	_, _ = registry.UpdateAccount(created.ID, AccountUpdate{InRotation: ptr(true)})

	readopted := adoptSubscription(t, registry, AdoptRequest{InRotation: ptr(false)})
	if !readopted.IsInRotation() {
		t.Fatal("re-adopting overwrote a setting another machine had changed")
	}
}

func TestAnUnreadableGroupsFileIsRefusedAndNeverOverwritten(t *testing.T) {
	registry, secrets := newTestRegistry(t, subscriptionStub())
	adoptSubscription(t, registry, AdoptRequest{})
	if err := os.WriteFile(registry.groupsFile, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	restarted := NewRegistry(registry.client, secrets, registry.accountsFile)
	restarted.Bootstrap()
	if _, err := restarted.Groups(); err != ErrGroupsUnavailable {
		t.Fatalf("an unreadable file must be refused, not served as no groups: %v", err)
	}
	if _, err := restarted.CreateGroup("New"); err != ErrGroupsUnavailable {
		t.Fatalf("creating must be refused too: %v", err)
	}
	_, _ = restarted.UpdateAccount("acct-1", AccountUpdate{Label: ptr("still saves")})
	raw, _ := os.ReadFile(restarted.groupsFile)
	if string(raw) != "{not json" {
		t.Fatalf("the unreadable file was overwritten: %s", raw)
	}
}

func TestAMembershipOfAGroupThatNoLongerExistsIsDropped(t *testing.T) {
	registry, secrets := newTestRegistry(t, subscriptionStub())
	account := adoptSubscription(t, registry, AdoptRequest{})
	group, _ := registry.CreateGroup("Gone")
	_, _ = registry.UpdateAccount(account.ID, AccountUpdate{GroupID: ptr(group.ID)})
	if err := os.Remove(filepath.Join(filepath.Dir(registry.accountsFile), "groups.json")); err != nil {
		t.Fatal(err)
	}

	restarted := NewRegistry(registry.client, secrets, registry.accountsFile)
	restarted.Bootstrap()
	if restarted.List()[0].GroupID != nil {
		t.Fatal("an account kept a group nobody can see")
	}
}

func TestALoginKeepsTheNameItWasGiven(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
		"/v1/oauth/token": {200,
			`{"access_token":"fresh","expires_in":28800,"refresh_token":"r1"}`},
	})
	registry, _ := newTestRegistry(t, stub)
	started, _ := registry.StartLogin(LoginStartRequest{RedirectPort: 1234})
	account, err := registry.FinishLogin(context.Background(), LoginFinishRequest{
		LoginID: started.LoginID, Code: "code", State: ptr(started.State),
		Label: ptr("Project seat")})
	if err != nil {
		t.Fatal(err)
	}
	if account.Label != "Project seat" {
		t.Fatalf("the name given at sign-in was dropped: %q", account.Label)
	}
}

func TestARefreshPollsAtMostOncePerFloor(t *testing.T) {
	stub := subscriptionStub()
	registry, _ := newTestRegistry(t, stub)
	account := adoptSubscription(t, registry, AdoptRequest{})
	// Adopt polls in the background; wait for it so the counts below are only ours.
	deadline := time.Now().Add(5 * time.Second)
	for stub.count("/api/oauth/usage") == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	before := stub.count("/api/oauth/usage")

	if _, ok := registry.RefreshUsage(context.Background(), account.ID); !ok {
		t.Fatal("expected usage")
	}
	if stub.count("/api/oauth/usage") != before {
		t.Fatal("a refresh right after a poll must answer from the cache")
	}

	registry.mu.Lock()
	registry.usage[account.ID].LastEndpointFetch = time.Now().Add(-forcedPollFloor)
	registry.mu.Unlock()
	_, _ = registry.RefreshUsage(context.Background(), account.ID)
	_, _ = registry.RefreshUsage(context.Background(), account.ID)
	if got := stub.count("/api/oauth/usage") - before; got != 1 {
		t.Fatalf("expected exactly one forced poll, got %d", got)
	}
}

func TestEndToEndGroupsAndAccountSettings(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	server, _, client := startTestServer(t, registry)
	account := adoptSubscription(t, registry, AdoptRequest{})

	decode := func(resp *http.Response, status int, into any) {
		t.Helper()
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != status {
			t.Fatalf("expected %d, got %d: %s", status, resp.StatusCode, body)
		}
		if into != nil {
			if err := json.Unmarshal(body, into); err != nil {
				t.Fatal(err)
			}
		}
	}

	var group SubscriptionGroup
	decode(authed(t, client, http.MethodPost, server.URL+"/v1/groups",
		`{"name":"Cossacks"}`), http.StatusOK, &group)
	var renamed SubscriptionGroup
	decode(authed(t, client, http.MethodPatch, server.URL+"/v1/groups/"+group.ID,
		`{"name":"Cossacks 3"}`), http.StatusOK, &renamed)
	var updated RemoteAccount
	decode(authed(t, client, http.MethodPatch, server.URL+"/v1/accounts/"+account.ID,
		`{"groupID":"`+group.ID+`","inRotation":false}`), http.StatusOK, &updated)
	if updated.Group() != group.ID || updated.IsInRotation() {
		t.Fatalf("update not applied: %+v", updated)
	}
	var listed GroupListResponse
	decode(authed(t, client, http.MethodGet, server.URL+"/v1/groups", ""),
		http.StatusOK, &listed)
	if len(listed.Groups) != 1 || listed.Groups[0].Name != "Cossacks 3" {
		t.Fatalf("unexpected groups: %+v", listed)
	}

	decode(authed(t, client, http.MethodPatch, server.URL+"/v1/accounts/nobody",
		`{"label":"x"}`), http.StatusNotFound, nil)
	decode(authed(t, client, http.MethodPost, server.URL+"/v1/groups", `{"name":"  "}`),
		http.StatusBadRequest, nil)
	decode(authed(t, client, http.MethodDelete, server.URL+"/v1/groups/"+group.ID, ""),
		http.StatusNoContent, nil)
	decode(authed(t, client, http.MethodDelete, server.URL+"/v1/groups/"+group.ID, ""),
		http.StatusNotFound, nil)
	decode(authed(t, client, http.MethodPost,
		server.URL+"/v1/accounts/"+account.ID+"/usage/refresh", ""), http.StatusOK, nil)
}

// A client mirrors what it is told, so serving an unreadable file as no accounts would
// remove every account from every Mac — and the next save would make that permanent.
func TestAnUnreadableAccountsFileIsRefusedAndNeverOverwritten(t *testing.T) {
	registry, secrets := newTestRegistry(t, subscriptionStub())
	if err := os.WriteFile(registry.accountsFile, []byte("[{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	restarted := NewRegistry(registry.client, secrets, registry.accountsFile)
	restarted.Bootstrap()
	server, _, client := startTestServer(t, restarted)

	resp := authed(t, client, http.MethodGet, server.URL+"/v1/accounts", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", resp.StatusCode)
	}
	if _, err := restarted.Adopt(context.Background(), AdoptRequest{CredentialJSON: ptr(
		credentialJSON("a", "r", time.Now().Add(time.Hour)))}); err != ErrAccountsUnavailable {
		t.Fatalf("an adopt must be refused, not kept in memory only: %v", err)
	}
	restarted.persist()
	raw, _ := os.ReadFile(restarted.accountsFile)
	if string(raw) != "[{broken" {
		t.Fatalf("the unreadable file was overwritten: %s", raw)
	}
}

func TestARelayedReloginKeepsTheSharedName(t *testing.T) {
	stub := newStub(map[string]stubReply{
		"/api/oauth/profile": {200, profileJSON},
		"/api/oauth/usage":   {200, "{}"},
		"/v1/oauth/token": {200,
			`{"access_token":"fresh","expires_in":28800,"refresh_token":"r1"}`},
	})
	registry, _ := newTestRegistry(t, stub)
	account := adoptSubscription(t, registry, AdoptRequest{})
	_, _ = registry.UpdateAccount(account.ID, AccountUpdate{Label: ptr("Team")})

	started, _ := registry.StartLogin(LoginStartRequest{RedirectPort: 1234})
	relogged, err := registry.FinishLogin(context.Background(), LoginFinishRequest{
		LoginID: started.LoginID, Code: "code", State: ptr(started.State),
		Label: ptr("stale name")})
	if err != nil {
		t.Fatal(err)
	}
	if relogged.Label != "Team" {
		t.Fatalf("a re-login replaced the shared name: %q", relogged.Label)
	}
}

func TestDeletingAnUnknownAccountIsANotFound(t *testing.T) {
	registry, _ := newTestRegistry(t, subscriptionStub())
	server, _, client := startTestServer(t, registry)
	resp := authed(t, client, http.MethodDelete, server.URL+"/v1/accounts/nobody", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}
