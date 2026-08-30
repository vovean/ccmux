package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func session(id, accountID string) MachineSession {
	return MachineSession{ID: id, AccountID: accountID, AccountLabel: "Work",
		Name: id, Policy: "opus", Status: "busy", StartedSecondsAgo: 60}
}

func snapshotFor(t *testing.T, store *MachineStore, machineID string,
	now time.Time) (MachineSnapshot, bool) {
	t.Helper()
	for _, snapshot := range store.Snapshots(now) {
		if snapshot.MachineID == machineID {
			return snapshot, true
		}
	}
	return MachineSnapshot{}, false
}

// The whole liveness model in one test: a report is a snapshot, not a delta, so a session
// that ended is gone because it is absent — no delete call, and nothing to reap.
func TestAReportReplacesTheWholeList(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()

	store.Report("m1", MachineReport{Label: "studio",
		Sessions: []MachineSession{session("a", "acct"), session("b", "acct")}}, now)
	store.Report("m1", MachineReport{Label: "studio",
		Sessions: []MachineSession{session("b", "acct")}}, now.Add(20*time.Second))

	snapshot, ok := snapshotFor(t, store, "m1", now.Add(20*time.Second))
	if !ok {
		t.Fatal("the machine should still be there")
	}
	if len(snapshot.Sessions) != 1 || snapshot.Sessions[0].ID != "b" {
		t.Fatalf("expected only b, got %+v", snapshot.Sessions)
	}
}

func TestAgeIsMeasuredFromTheLastReport(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	store.Report("m1", MachineReport{Label: "studio"}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now.Add(90*time.Second))
	if snapshot.AgeSeconds < 89 || snapshot.AgeSeconds > 91 {
		t.Fatalf("expected ~90s, got %v", snapshot.AgeSeconds)
	}
}

// A clock that steps backwards — NTP, or a laptop waking — must not produce an age the
// client would read as a session started in the future.
func TestAgeNeverGoesNegative(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	store.Report("m1", MachineReport{Label: "studio"}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now.Add(-time.Hour))
	if snapshot.AgeSeconds != 0 {
		t.Fatalf("expected 0, got %v", snapshot.AgeSeconds)
	}
}

func TestASilentMachineIsForgottenAfterTheTTL(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	store.Report("gone", MachineReport{Label: "old"}, now)
	store.Report("here", MachineReport{Label: "current"}, now.Add(machineTTL))

	later := now.Add(machineTTL + time.Minute)
	if _, ok := snapshotFor(t, store, "gone", later); ok {
		t.Fatal("a machine silent past the TTL should be gone")
	}
	if _, ok := snapshotFor(t, store, "here", later); !ok {
		t.Fatal("the machine that reported recently should have survived")
	}
}

// The daemon runs under MemoryMax=192M beside the VPN processes, so a client looping on
// fresh machine ids must not be able to grow it without bound.
func TestTheMachineCountIsCapped(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	for i := 0; i < maxMachines+8; i++ {
		store.Report(fmt.Sprintf("m%02d", i), MachineReport{Label: "x"},
			now.Add(time.Duration(i)*time.Second))
	}
	final := now.Add(time.Duration(maxMachines+8) * time.Second)
	if got := store.Count(final); got != maxMachines {
		t.Fatalf("expected %d machines, got %d", maxMachines, got)
	}
	// The oldest went first, so the most recent reporters are the ones still here.
	if _, ok := snapshotFor(t, store, "m00", final); ok {
		t.Fatal("the oldest machine should have been evicted")
	}
	if _, ok := snapshotFor(t, store, fmt.Sprintf("m%02d", maxMachines+7), final); !ok {
		t.Fatal("the newest machine should be present")
	}
}

// Re-reporting under an id already known must not count against the cap, or a steady
// fleet of exactly maxMachines would evict one of its own on every tick.
func TestReReportingDoesNotEvict(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	for i := 0; i < maxMachines; i++ {
		store.Report(fmt.Sprintf("m%02d", i), MachineReport{Label: "x"},
			now.Add(time.Duration(i)*time.Second))
	}
	store.Report("m00", MachineReport{Label: "x"}, now.Add(time.Hour))
	if got := store.Count(now.Add(time.Hour)); got != maxMachines {
		t.Fatalf("expected %d machines, got %d", maxMachines, got)
	}
	if _, ok := snapshotFor(t, store, "m01", now.Add(time.Hour)); !ok {
		t.Fatal("re-reporting an existing machine should not have evicted another")
	}
}

func TestSessionsPerMachineAreCapped(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	var sessions []MachineSession
	for i := 0; i < maxSessionsPerMachine+50; i++ {
		sessions = append(sessions, session(fmt.Sprintf("s%d", i), "acct"))
	}
	store.Report("m1", MachineReport{Label: "studio", Sessions: sessions}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now)
	if len(snapshot.Sessions) != maxSessionsPerMachine {
		t.Fatalf("expected %d sessions, got %d", maxSessionsPerMachine,
			len(snapshot.Sessions))
	}
}

// Truncating bytes instead of runes leaves invalid UTF-8, which json.Marshal silently
// replaces with U+FFFD — the client would then show a directory ending in a black
// diamond rather than a truncated path.
func TestLongFieldsAreTruncatedOnARuneBoundary(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	long := strings.Repeat("ю", maxFieldRunes+40)
	entry := session("s1", "acct")
	entry.Name = long
	entry.Directory = ptr(long)
	store.Report("m1", MachineReport{Label: long, Sessions: []MachineSession{entry}}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now)
	if count := len([]rune(snapshot.Label)); count != maxFieldRunes {
		t.Fatalf("label kept %d runes", count)
	}
	got := snapshot.Sessions[0]
	if count := len([]rune(got.Name)); count != maxFieldRunes {
		t.Fatalf("name kept %d runes", count)
	}
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `�`) {
		t.Fatal("truncation split a multi-byte character")
	}
}

// Go marshals a nil slice as null, and the client's `sessions: [MachineSession]` is not
// optional — it throws on null and the whole response is lost.
func TestAMachineWithNoSessionsMarshalsAsAnEmptyArray(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	store.Report("m1", MachineReport{Label: "studio"}, now)

	encoded, err := json.Marshal(SessionsResponse{APIVersion: apiVersion,
		Machines: store.Snapshots(now)})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `"sessions":null`) {
		t.Fatalf("nil slice reached the wire: %s", encoded)
	}
	if !strings.Contains(string(encoded), `"sessions":[]`) {
		t.Fatalf("expected an empty array: %s", encoded)
	}
}

// Ages and spend arrive as bare float64 and are formatted straight into a Mac's UI, where
// converting to an integer traps — on NaN and on anything past Int.max — and a fatal error
// inside a SwiftUI view body takes the window with it. Bounded here, at the one place
// every report passes through.
func TestHostileNumbersAreClampedBeforeTheyReachAnyClient(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	nan := math.NaN()

	cases := []struct {
		name    string
		started float64
		updated *float64
		spend   float64
	}{
		{"nan", nan, &nan, nan},
		{"positive infinity", math.Inf(1), ptr(math.Inf(1)), math.Inf(1)},
		{"negative infinity", math.Inf(-1), ptr(math.Inf(-1)), math.Inf(-1)},
		{"absurdly large", 1e300, ptr(1e300), 1e300},
		{"negative", -5, ptr(-5.0), -5},
	}

	for _, tc := range cases {
		entry := session("s1", "acct")
		entry.StartedSecondsAgo = tc.started
		entry.UpdatedSecondsAgo = tc.updated
		entry.SpendUSD = tc.spend
		store.Report("m1", MachineReport{Label: "studio",
			Sessions: []MachineSession{entry}}, now)

		snapshot, _ := snapshotFor(t, store, "m1", now)
		got := snapshot.Sessions[0]
		for label, value := range map[string]float64{
			"startedSecondsAgo": got.StartedSecondsAgo,
			"updatedSecondsAgo": *got.UpdatedSecondsAgo,
			"spendUSD":          got.SpendUSD,
		} {
			if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
				t.Errorf("%s: %s came back as %v", tc.name, label, value)
			}
		}
		if got.StartedSecondsAgo > maxReportedSeconds {
			t.Errorf("%s: startedSecondsAgo was %v", tc.name, got.StartedSecondsAgo)
		}
		if got.SpendUSD > maxReportedSpendUSD {
			t.Errorf("%s: spendUSD was %v", tc.name, got.SpendUSD)
		}

		// NaN and infinity cannot be marshalled at all, so a single one that slipped
		// through would fail the whole response for every machine.
		if _, err := json.Marshal(snapshot); err != nil {
			t.Errorf("%s: %v", tc.name, err)
		}
	}
}

func TestOrdinaryNumbersPassThroughUntouched(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	entry := session("s1", "acct")
	entry.StartedSecondsAgo = 3600.5
	entry.UpdatedSecondsAgo = ptr(12.25)
	entry.SpendUSD = 1.25
	store.Report("m1", MachineReport{Label: "studio",
		Sessions: []MachineSession{entry}}, now)

	got := func() MachineSession {
		snapshot, _ := snapshotFor(t, store, "m1", now)
		return snapshot.Sessions[0]
	}()
	if got.StartedSecondsAgo != 3600.5 || *got.UpdatedSecondsAgo != 12.25 ||
		got.SpendUSD != 1.25 {
		t.Fatalf("clamping altered a normal report: %+v", got)
	}
}

// A machine id carrying a control character is refused outright. These fields cannot be
// refused without dropping an otherwise legitimate report, so they are stripped — every
// one of them is rendered verbatim in another Mac's window.
func TestControlCharactersAreStrippedFromEveryField(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	entry := session("s\x001", "acct")
	entry.Name = "api\ngateway"
	entry.Status = "busy\r"
	entry.Directory = ptr("/tmp/we\x07ird")
	store.Report("m1", MachineReport{Label: "studio\n\nfake row",
		Sessions: []MachineSession{entry}}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now)
	got := snapshot.Sessions[0]
	for label, value := range map[string]string{
		"machine label": snapshot.Label,
		"id":            got.ID,
		"name":          got.Name,
		"status":        got.Status,
		"directory":     *got.Directory,
	} {
		if strings.IndexFunc(value, func(r rune) bool {
			return r < 0x20 || r == 0x7f
		}) >= 0 {
			t.Errorf("%s kept a control character: %q", label, value)
		}
	}
	if snapshot.Label != "studiofake row" {
		t.Errorf("label was %q", snapshot.Label)
	}
	if got.Name != "apigateway" {
		t.Errorf("name was %q", got.Name)
	}
}

func TestOrdinaryTextIsLeftAlone(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	entry := session("s1", "acct")
	entry.Name = "api — ГЛАВНЫЙ 🚀"
	entry.Directory = ptr("/Users/someone/dev/api")
	store.Report("m1", MachineReport{Label: "the studio Mac",
		Sessions: []MachineSession{entry}}, now)

	snapshot, _ := snapshotFor(t, store, "m1", now)
	if snapshot.Label != "the studio Mac" {
		t.Errorf("label was %q", snapshot.Label)
	}
	if snapshot.Sessions[0].Name != "api — ГЛАВНЫЙ 🚀" {
		t.Errorf("name was %q", snapshot.Sessions[0].Name)
	}
}

func TestForgetOnlyReportsRemovingSomethingThatWasThere(t *testing.T) {
	store := NewMachineStore()
	store.Report("m1", MachineReport{Label: "studio"}, time.Now())
	if !store.Forget("m1") {
		t.Fatal("should have reported the removal")
	}
	if store.Forget("m1") {
		t.Fatal("a second removal should report nothing was there")
	}
}

func TestMachineIDValidation(t *testing.T) {
	if !ValidMachineID("8f0f1b64-0000-4000-8000-000000000001") {
		t.Fatal("a UUID should be accepted")
	}
	for _, bad := range []string{"", "   ", strings.Repeat("x", maxMachineIDRunes+1),
		"line\nbreak", "null\x00byte"} {
		if ValidMachineID(bad) {
			t.Errorf("should have rejected %q", bad)
		}
	}
}

func TestConcurrentReportsAndReads(t *testing.T) {
	store := NewMachineStore()
	now := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(2)
		id := fmt.Sprintf("m%d", i%4)
		go func() {
			defer wg.Done()
			store.Report(id, MachineReport{Label: id,
				Sessions: []MachineSession{session("s", "acct")}}, now)
		}()
		go func() {
			defer wg.Done()
			_ = store.Snapshots(now)
		}()
	}
	wg.Wait()
}

// ---------------------------------------------------------------- over HTTP

func TestReportingReturnsTheWholeWorld(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	machines := NewMachineStore()
	server, _, client := startTestServerWith(t, registry, machines)

	body := `{"label":"studio","sessions":[{"id":"s1","accountID":"acct-1",` +
		`"accountLabel":"Work","name":"api","policy":"opus","status":"busy",` +
		`"startedSecondsAgo":42,"spendUSD":0}]}`
	resp := authed(t, client, "POST", server.URL+"/v1/machines/studio-id/sessions", body)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var decoded SessionsResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.APIVersion != apiVersion {
		t.Fatalf("apiVersion %d", decoded.APIVersion)
	}
	// The reporter is included: a GET carries no machine identity, so the client filters
	// its own id either way and the server has one behaviour rather than two.
	if len(decoded.Machines) != 1 || decoded.Machines[0].MachineID != "studio-id" {
		t.Fatalf("expected the reporter back, got %+v", decoded.Machines)
	}
	if len(decoded.Machines[0].Sessions) != 1 ||
		decoded.Machines[0].Sessions[0].ID != "s1" {
		t.Fatalf("session did not survive the round trip: %+v", decoded.Machines[0])
	}
}

func TestSessionsCanBeFetchedWithoutReporting(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	machines := NewMachineStore()
	machines.Report("other", MachineReport{Label: "laptop",
		Sessions: []MachineSession{session("s1", "acct")}}, time.Now())
	server, _, client := startTestServerWith(t, registry, machines)

	resp := authed(t, client, "GET", server.URL+"/v1/sessions", "")
	defer resp.Body.Close()
	var decoded SessionsResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Machines) != 1 || decoded.Machines[0].Label != "laptop" {
		t.Fatalf("got %+v", decoded.Machines)
	}
}

func TestAnUnusableMachineIDIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	resp := authed(t, client, "POST", server.URL+"/v1/machines/%20/sessions",
		`{"label":"x","sessions":[]}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

func TestForgettingAMachineOverHTTP(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	machines := NewMachineStore()
	machines.Report("m1", MachineReport{Label: "studio"}, time.Now())
	server, _, client := startTestServerWith(t, registry, machines)

	resp := authed(t, client, "DELETE", server.URL+"/v1/machines/m1", "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", resp.StatusCode)
	}
	again := authed(t, client, "DELETE", server.URL+"/v1/machines/m1", "")
	again.Body.Close()
	if again.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", again.StatusCode)
	}
}

// The id is echoed back in the 404 below and a Mac shows it verbatim in a banner, so it
// is checked here as well as on the way in.
func TestForgettingRefusesAnUnusableMachineID(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	resp := authed(t, client, "DELETE", server.URL+"/v1/machines/%20", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// How a client tells this build from the one already deployed, which answers 404 on every
// route above and must not be reported to the user as a broken server.
func TestHealthAdvertisesTheSessionFeature(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	machines := NewMachineStore()
	machines.Report("m1", MachineReport{Label: "studio"}, time.Now())
	server, _, client := startTestServerWith(t, registry, machines)

	resp := authed(t, client, "GET", server.URL+"/v1/health", "")
	defer resp.Body.Close()
	var health HealthResponse
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, feature := range health.Features {
		if feature == featureSessions {
			found = true
		}
	}
	if !found {
		t.Fatalf("features were %v", health.Features)
	}
	if health.Machines != 1 {
		t.Fatalf("machines was %d", health.Machines)
	}
}

func TestTheSessionRoutesNeedAuth(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	cases := [][2]string{
		{"GET", "/v1/sessions"},
		{"POST", "/v1/machines/m1/sessions"},
		{"DELETE", "/v1/machines/m1"},
	}
	for _, tc := range cases {
		req, err := http.NewRequest(tc[0], server.URL+tc[1], strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s %s answered %d without credentials", tc[0], tc[1],
				resp.StatusCode)
		}
	}
}
