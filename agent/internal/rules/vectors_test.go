package rules

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"ccmuxd/wire"
)

// The cross-language rule vectors.
//
// These rules exist twice — here and in the Mac's ModelRouting / UsageParser /
// UsageSnapshot.folding — and nothing either compiler does can notice the two drifting
// apart. The files this generates are decoded by Tests/CCMuxKitTests/RuleVectorTests.swift
// and asserted against the Swift implementations, exactly as server/testdata/wire pins
// the JSON shapes.
//
// Regenerate with: UPDATE_FIXTURES=1 go test ./internal/rules/
// Then run `make test` and make sure the Swift side still agrees.

type vecAccount struct {
	ID     string             `json:"id"`
	Label  string             `json:"label"`
	Kind   wire.AccountKind   `json:"kind"`
	Health wire.AccountHealth `json:"health"`
}

type vecSnapshot struct {
	Windows           []wire.UsageWindow `json:"windows"`
	FetchedAt         wire.Time          `json:"fetchedAt"`
	LastEndpointFetch wire.Time          `json:"lastEndpointFetchAt"`
}

type rankCase struct {
	Name             string                 `json:"name"`
	Model            string                 `json:"model"`
	Accounts         []vecAccount           `json:"accounts"`
	Usage            map[string]vecSnapshot `json:"usage"`
	Excluded         []string               `json:"excluded"`
	ExpectedOrder    []string               `json:"expectedOrder"`
	ExpectedCanServe map[string]bool        `json:"expectedCanServe"`
}

type availCase struct {
	Name                string                 `json:"name"`
	Model               string                 `json:"model"`
	Now                 wire.Time              `json:"now"`
	Accounts            []vecAccount           `json:"accounts"`
	Usage               map[string]vecSnapshot `json:"usage"`
	ExpectedAvailableAt map[string]wire.Time   `json:"expectedAvailableAt"`
	ExpectedUnknowable  []string               `json:"expectedUnknowable"`
	// Nil rather than empty: "no account can ever serve this" is a real answer, and an
	// empty string is not a value the other side can tell apart from a missing field.
	ExpectedSoonestID *string    `json:"expectedSoonestAccountID"`
	ExpectedSoonestAt *wire.Time `json:"expectedSoonestAt"`
}

type foldCase struct {
	Name       string             `json:"name"`
	Previous   *vecSnapshot       `json:"previous"`
	Windows    []wire.UsageWindow `json:"windows"`
	ObservedAt wire.Time          `json:"observedAt"`
	Expected   vecSnapshot        `json:"expected"`
}

type headerFoldCase struct {
	Name       string             `json:"name"`
	Previous   *vecSnapshot       `json:"previous"`
	Windows    []wire.UsageWindow `json:"windows"`
	ObservedAt wire.Time          `json:"observedAt"`
	Expected   vecSnapshot        `json:"expected"`
}

type headerCase struct {
	Name            string             `json:"name"`
	Headers         map[string]string  `json:"headers"`
	StatusCode      int                `json:"statusCode"`
	ExpectedWindows []wire.UsageWindow `json:"expectedWindows"`
	ExpectedLimited bool               `json:"expectedRateLimited"`
}

type resetCase struct {
	Name     string    `json:"name"`
	Headers  []Header  `json:"headers"`
	To       wire.Time `json:"to"`
	Now      wire.Time `json:"now"`
	Changed  bool      `json:"changed"`
	Expected []Header  `json:"expected"`
}

type scopeCase struct {
	Name      string `json:"name"`
	ModelName string `json:"modelName"`
	ModelID   string `json:"modelID"`
	Expected  bool   `json:"expected"`
}

var noon = time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)

func at(offset time.Duration) wire.Time { return wire.Time{Time: noon.Add(offset)} }

func window(kind wire.WindowKind, percent float64, model string, resets *time.Duration) wire.UsageWindow {
	w := wire.UsageWindow{Kind: kind, Percent: percent}
	switch kind {
	case wire.WindowSession:
		w.Label = "5-hour"
	case wire.WindowWeeklyAll:
		w.Label = "Weekly"
	case wire.WindowWeeklyScoped:
		w.Label = "Weekly " + model
		w.ModelName = wire.Ptr(model)
	default:
		w.Label = "Other"
	}
	if resets != nil {
		w.ResetsAt = wire.Ptr(at(*resets))
	}
	return w
}

func after(d time.Duration) *time.Duration { return &d }

func snap(windows ...wire.UsageWindow) vecSnapshot {
	return vecSnapshot{Windows: windows, FetchedAt: at(0), LastEndpointFetch: at(0)}
}

func (v vecSnapshot) rules() *Snapshot {
	return &Snapshot{Windows: v.Windows, FetchedAt: v.FetchedAt.Time,
		LastEndpointFetch: v.LastEndpointFetch.Time}
}

func accountsOf(cases []vecAccount) []wire.RemoteAccount {
	out := make([]wire.RemoteAccount, 0, len(cases))
	for _, a := range cases {
		out = append(out, wire.RemoteAccount{ID: a.ID, Label: a.Label, Kind: a.Kind, Health: a.Health})
	}
	return out
}

func usageOf(raw map[string]vecSnapshot) map[string]*Snapshot {
	out := make(map[string]*Snapshot, len(raw))
	for id, s := range raw {
		out[id] = s.rules()
	}
	return out
}

func sub(id, label string) vecAccount {
	return vecAccount{ID: id, Label: label, Kind: wire.KindSubscription, Health: wire.HealthOK}
}

func rankCases() []rankCase {
	three := []vecAccount{sub("fresh", "Fresh"), sub("half", "Half"), sub("nearly", "Nearly")}
	full := map[string]vecSnapshot{
		"fresh":  snap(window(wire.WindowSession, 5, "", nil), window(wire.WindowWeeklyAll, 5, "", nil)),
		"half":   snap(window(wire.WindowSession, 5, "", nil), window(wire.WindowWeeklyAll, 50, "", nil)),
		"nearly": snap(window(wire.WindowSession, 5, "", nil), window(wire.WindowWeeklyAll, 90, "", nil)),
	}
	return []rankCase{
		{
			Name:     "the most drained eligible account comes first",
			Model:    "claude-opus-5",
			Accounts: three,
			Usage:    full,
		},
		{
			Name:     "a fable request will not take an account with no fable week left",
			Model:    "claude-fable-5-1",
			Accounts: []vecAccount{sub("a", "A"), sub("b", "B")},
			Usage: map[string]vecSnapshot{
				// `a` has plenty of general weekly but its Fable week is spent.
				"a": snap(window(wire.WindowSession, 10, "", nil),
					window(wire.WindowWeeklyAll, 10, "", nil),
					window(wire.WindowWeeklyScoped, 100, "Fable", nil)),
				"b": snap(window(wire.WindowSession, 10, "", nil),
					window(wire.WindowWeeklyAll, 80, "", nil),
					window(wire.WindowWeeklyScoped, 20, "Fable", nil)),
			},
		},
		{
			Name:     "a spent fable week does not stop an opus request",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{sub("a", "A"), sub("b", "B")},
			Usage: map[string]vecSnapshot{
				"a": snap(window(wire.WindowSession, 10, "", nil),
					window(wire.WindowWeeklyAll, 10, "", nil),
					window(wire.WindowWeeklyScoped, 100, "Fable", nil)),
				"b": snap(window(wire.WindowSession, 10, "", nil),
					window(wire.WindowWeeklyAll, 80, "", nil)),
			},
		},
		{
			Name:     "an unmeasured account sorts mid-pack rather than first or last",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{sub("drained", "Drained"), sub("unknown", "Unknown"), sub("fresh", "Fresh")},
			Usage: map[string]vecSnapshot{
				"drained": snap(window(wire.WindowWeeklyAll, 80, "", nil)),
				"fresh":   snap(window(wire.WindowWeeklyAll, 10, "", nil)),
			},
		},
		{
			Name:     "an account needing re-login is never ranked",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{{ID: "dead", Label: "Dead", Kind: wire.KindSubscription, Health: wire.HealthNeedsRelogin}, sub("live", "Live")},
			Usage: map[string]vecSnapshot{
				"dead": snap(window(wire.WindowWeeklyAll, 1, "", nil)),
				"live": snap(window(wire.WindowWeeklyAll, 50, "", nil)),
			},
		},
		{
			Name:     "an excluded account is skipped even with headroom",
			Model:    "claude-opus-5",
			Accounts: three,
			Usage:    full,
			Excluded: []string{"nearly"},
		},
		{
			Name:     "ranking is on the weekly window, never the five-hour one",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{sub("a", "A"), sub("b", "B")},
			Usage: map[string]vecSnapshot{
				// `a` has barely any 5-hour left but the most week; it must rank last.
				"a": snap(window(wire.WindowSession, 95, "", nil), window(wire.WindowWeeklyAll, 10, "", nil)),
				"b": snap(window(wire.WindowSession, 5, "", nil), window(wire.WindowWeeklyAll, 60, "", nil)),
			},
		},
		{
			Name:     "an exhausted five-hour window still makes an account ineligible",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{sub("a", "A"), sub("b", "B")},
			Usage: map[string]vecSnapshot{
				"a": snap(window(wire.WindowSession, 100, "", nil), window(wire.WindowWeeklyAll, 1, "", nil)),
				"b": snap(window(wire.WindowSession, 5, "", nil), window(wire.WindowWeeklyAll, 60, "", nil)),
			},
		},
		{
			Name:     "a per-minute ceiling never makes an account the wrong choice",
			Model:    "claude-opus-5",
			Accounts: []vecAccount{sub("a", "A")},
			Usage: map[string]vecSnapshot{
				"a": snap(window(wire.WindowOther, 100, "", nil), window(wire.WindowWeeklyAll, 10, "", nil)),
			},
		},
	}
}

func availCases() []availCase {
	return []availCase{
		{
			Name:     "an account with headroom is available now",
			Model:    "claude-opus-5",
			Now:      at(0),
			Accounts: []vecAccount{sub("a", "A")},
			Usage:    map[string]vecSnapshot{"a": snap(window(wire.WindowWeeklyAll, 10, "", nil))},
		},
		{
			Name:     "every blocking window has to clear, so the last reset wins",
			Model:    "claude-fable-5-1",
			Now:      at(0),
			Accounts: []vecAccount{sub("a", "A")},
			Usage: map[string]vecSnapshot{
				"a": snap(window(wire.WindowSession, 100, "", after(time.Hour)),
					window(wire.WindowWeeklyScoped, 100, "Fable", after(6*time.Hour))),
			},
		},
		{
			Name:     "a blocked window with no reset makes the answer unknowable",
			Model:    "claude-opus-5",
			Now:      at(0),
			Accounts: []vecAccount{sub("a", "A")},
			Usage:    map[string]vecSnapshot{"a": snap(window(wire.WindowWeeklyAll, 100, "", nil))},
		},
		{
			Name:  "the soonest is the earliest of several, and an unknowable one is passed over",
			Model: "claude-opus-5",
			Now:   at(0),
			Accounts: []vecAccount{sub("late", "Late"), sub("soon", "Soon"), sub("never", "Never"),
				{ID: "dead", Label: "Dead", Kind: wire.KindSubscription, Health: wire.HealthNeedsRelogin}},
			Usage: map[string]vecSnapshot{
				"late":  snap(window(wire.WindowWeeklyAll, 100, "", after(5*time.Hour))),
				"soon":  snap(window(wire.WindowWeeklyAll, 100, "", after(time.Hour))),
				"never": snap(window(wire.WindowWeeklyAll, 100, "", nil)),
				// Healthy and free right now, but needs re-login, so it is not an answer.
				"dead": snap(window(wire.WindowWeeklyAll, 1, "", nil)),
			},
		},
	}
}

func foldCases() []foldCase {
	held := vecSnapshot{
		Windows:           []wire.UsageWindow{window(wire.WindowSession, 36, "", nil)},
		FetchedAt:         at(0),
		LastEndpointFetch: at(-10 * time.Minute),
	}
	heldWithScoped := vecSnapshot{
		Windows: []wire.UsageWindow{window(wire.WindowSession, 36, "", nil),
			window(wire.WindowWeeklyScoped, 100, "Fable", nil)},
		FetchedAt:         at(0),
		LastEndpointFetch: at(-10 * time.Minute),
	}
	return []foldCase{
		{
			Name:       "a late answer does not lower a header-fresh window",
			Previous:   &held,
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 27, "", nil)},
			ObservedAt: at(-280 * time.Second),
		},
		{
			Name:     "a late answer still carries the windows only it reports",
			Previous: &held,
			Windows: []wire.UsageWindow{window(wire.WindowSession, 27, "", nil),
				window(wire.WindowWeeklyScoped, 17, "Fable", nil)},
			ObservedAt: at(-280 * time.Second),
		},
		{
			Name:       "a late answer drops a per-model window it no longer reports",
			Previous:   &heldWithScoped,
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 27, "", nil)},
			ObservedAt: at(-280 * time.Second),
		},
		{
			Name: "an answer older than the last endpoint read changes nothing",
			Previous: &vecSnapshot{
				Windows: []wire.UsageWindow{window(wire.WindowSession, 36, "", nil),
					window(wire.WindowWeeklyScoped, 50, "Fable", nil)},
				FetchedAt:         at(0),
				LastEndpointFetch: at(-100 * time.Second),
			},
			Windows:    []wire.UsageWindow{window(wire.WindowWeeklyScoped, 17, "Fable", nil)},
			ObservedAt: at(-400 * time.Second),
		},
		{
			Name: "a current answer replaces what is held, including a window that is gone",
			Previous: &vecSnapshot{
				Windows: []wire.UsageWindow{window(wire.WindowSession, 36, "", nil),
					window(wire.WindowWeeklyScoped, 50, "Fable", nil)},
				FetchedAt:         at(-60 * time.Second),
				LastEndpointFetch: at(-60 * time.Second),
			},
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 99, "", nil)},
			ObservedAt: at(0),
		},
		{
			Name:       "with nothing held the answer is taken whole",
			Previous:   nil,
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 12, "", nil)},
			ObservedAt: at(0),
		},
	}
}

func headerFoldCases() []headerFoldCase {
	held := vecSnapshot{
		Windows: []wire.UsageWindow{
			window(wire.WindowSession, 10, "", nil),
			window(wire.WindowWeeklyAll, 96, "", nil),
			window(wire.WindowWeeklyScoped, 40, "Fable", nil),
		},
		FetchedAt:         at(-5 * time.Minute),
		LastEndpointFetch: at(-5 * time.Minute),
	}
	return []headerFoldCase{
		{
			Name:     "a response naming only the five-hour window leaves the weekly one alone",
			Previous: &held,
			// The weekly-all header is absent, as it is on any refusal and on a plan
			// with no weekly cap. Dropping the held window here would make an account
			// with 4% of its week left look like the freshest in the pool.
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 55, "", nil)},
			ObservedAt: at(0),
		},
		{
			Name:       "both windows are replaced when both are reported",
			Previous:   &held,
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 55, "", nil), window(wire.WindowWeeklyAll, 97, "", nil)},
			ObservedAt: at(0),
		},
		{
			Name:       "a response with no rate-limit headers changes nothing at all",
			Previous:   &held,
			Windows:    nil,
			ObservedAt: at(0),
		},
		{
			Name:       "with nothing held the headers are taken as they are",
			Previous:   nil,
			Windows:    []wire.UsageWindow{window(wire.WindowSession, 12, "", nil)},
			ObservedAt: at(0),
		},
	}
}

func headerCases() []headerCase {
	return []headerCase{
		{
			Name: "both unified windows, as fractions of the limit",
			Headers: map[string]string{
				"anthropic-ratelimit-unified-5h-utilization": "0.74",
				"anthropic-ratelimit-unified-5h-reset":       "1789459200",
				"anthropic-ratelimit-unified-7d-utilization": "0.11",
				"anthropic-ratelimit-unified-7d-reset":       "1789545600",
			},
			StatusCode: 200,
		},
		{
			Name:       "no rate-limit headers at all",
			Headers:    map[string]string{"content-type": "application/json"},
			StatusCode: 200,
		},
		{
			Name: "a utilization with no reset beside it is still a window",
			Headers: map[string]string{
				"anthropic-ratelimit-unified-5h-utilization": "0.5",
			},
			StatusCode: 200,
		},
		{
			Name:       "a 429 is a refusal whatever the headers say",
			Headers:    map[string]string{},
			StatusCode: 429,
		},
		{
			Name:       "so is a 200 the server marked rejected",
			Headers:    map[string]string{"anthropic-ratelimit-unified-status": "rejected"},
			StatusCode: 200,
		},
		{
			Name:       "an allowed status is not a refusal",
			Headers:    map[string]string{"anthropic-ratelimit-unified-status": "allowed"},
			StatusCode: 200,
		},
	}
}

func resetCases() []resetCase {
	far := "1789632000" // well past `to`
	return []resetCase{
		{
			Name: "a far upstream reset is shortened to when an account frees up",
			Headers: []Header{{"content-type", "application/json"},
				{"Anthropic-RateLimit-Unified-Reset", far}},
			To:  at(2 * time.Hour),
			Now: at(0),
		},
		{
			Name:    "a reset sooner than our answer is left alone",
			Headers: []Header{{"anthropic-ratelimit-unified-reset", "1789477200"}},
			To:      at(20 * time.Hour),
			Now:     at(0),
		},
		{
			Name:    "an answer of now is never written over a real reset",
			Headers: []Header{{"anthropic-ratelimit-unified-reset", far}},
			To:      at(0),
			Now:     at(0),
		},
		{
			Name:    "with no upstream reset the header is added",
			Headers: []Header{{"content-type", "application/json"}},
			To:      at(2 * time.Hour),
			Now:     at(0),
		},
	}
}

func scopeCases() []scopeCase {
	return []scopeCase{
		{Name: "a display name matches its model id", ModelName: "Fable", ModelID: "claude-fable-5-1", Expected: true},
		{Name: "separators and case are ignored", ModelName: "Sonnet 4.5", ModelID: "claude-sonnet-4-5", Expected: true},
		{Name: "a new generation of the same name still matches", ModelName: "Fable", ModelID: "claude-fable-6", Expected: true},
		{Name: "a different model does not match", ModelName: "Fable", ModelID: "claude-opus-5", Expected: false},
		{Name: "a name under three characters matches nothing", ModelName: "X1", ModelID: "claude-x1-5", Expected: false},
	}
}

// --- the assertions, which also fill in the expectations the vectors carry ---

func TestRuleVectors(t *testing.T) {
	ranks := rankCases()
	for i := range ranks {
		tc := &ranks[i]
		accounts := accountsOf(tc.Accounts)
		usage := usageOf(tc.Usage)
		excluded := map[string]bool{}
		for _, id := range tc.Excluded {
			excluded[id] = true
		}
		for _, id := range rankedIDs(RankLeastRemaining(tc.Model, accounts, usage, excluded)) {
			tc.ExpectedOrder = append(tc.ExpectedOrder, id)
		}
		tc.ExpectedCanServe = map[string]bool{}
		for _, account := range accounts {
			tc.ExpectedCanServe[account.ID] = CanServe(tc.Model, usage[account.ID])
		}
	}
	assertOrder(t, ranks)

	avails := availCases()
	for i := range avails {
		tc := &avails[i]
		accounts := accountsOf(tc.Accounts)
		usage := usageOf(tc.Usage)
		tc.ExpectedAvailableAt = map[string]wire.Time{}
		for _, account := range accounts {
			when, known := AvailableAt(tc.Model, usage[account.ID], tc.Now.Time)
			if known {
				tc.ExpectedAvailableAt[account.ID] = wire.Time{Time: when}
			} else {
				tc.ExpectedUnknowable = append(tc.ExpectedUnknowable, account.ID)
			}
		}
		id, when, ok := SoonestAvailable(tc.Model, accounts, usage, tc.Now.Time)
		if ok {
			tc.ExpectedSoonestID = wire.Ptr(id)
			tc.ExpectedSoonestAt = wire.Ptr(wire.Time{Time: when})
		}
	}
	assertAvailability(t, avails)

	folds := foldCases()
	for i := range folds {
		tc := &folds[i]
		var previous *Snapshot
		if tc.Previous != nil {
			previous = tc.Previous.rules()
		}
		got := FoldEndpoint(tc.Windows, previous, tc.ObservedAt.Time)
		tc.Windows = windowList(tc.Windows)
		tc.Expected = vecSnapshot{Windows: windowList(got.Windows),
			FetchedAt:         wire.Time{Time: got.FetchedAt},
			LastEndpointFetch: wire.Time{Time: got.LastEndpointFetch}}
	}
	assertFolding(t, folds)

	headerFolds := headerFoldCases()
	for i := range headerFolds {
		tc := &headerFolds[i]
		var previous *Snapshot
		if tc.Previous != nil {
			previous = tc.Previous.rules()
		}
		got := FoldHeaders(tc.Windows, previous, tc.ObservedAt.Time)
		tc.Windows = windowList(tc.Windows)
		tc.Expected = vecSnapshot{Windows: windowList(got.Windows),
			FetchedAt:         wire.Time{Time: got.FetchedAt},
			LastEndpointFetch: wire.Time{Time: got.LastEndpointFetch}}
	}
	assertHeaderFolding(t, headerFolds)

	headers := headerCases()
	for i := range headers {
		tc := &headers[i]
		tc.ExpectedWindows = windowList(WindowsFromHeaders(tc.Headers))
		tc.ExpectedLimited = IsRateLimited(tc.Headers, tc.StatusCode)
	}
	assertHeaders(t, headers)

	resets := resetCases()
	for i := range resets {
		tc := &resets[i]
		out, changed := ShorteningReset(tc.Headers, tc.To.Time, tc.Now.Time)
		tc.Changed, tc.Expected = changed, out
	}
	assertResets(t, resets)

	scopes := scopeCases()
	for _, tc := range scopes {
		got := Governs(wire.UsageWindow{Kind: wire.WindowWeeklyScoped,
			ModelName: wire.Ptr(tc.ModelName)}, tc.ModelID)
		if got != tc.Expected {
			t.Errorf("Governs(%q, %q) = %v, want %v", tc.ModelName, tc.ModelID, got, tc.Expected)
		}
	}

	writeVector(t, "ranking.json", map[string]any{"cases": ranks})
	writeVector(t, "availability.json", map[string]any{"cases": avails})
	writeVector(t, "folding.json", map[string]any{"cases": folds})
	writeVector(t, "header-folding.json", map[string]any{"cases": headerFolds})
	writeVector(t, "headers.json", map[string]any{"cases": headers})
	writeVector(t, "reset.json", map[string]any{"cases": resets})
	writeVector(t, "scoping.json", map[string]any{"cases": scopes})
}

func rankedIDs(accounts []wire.RemoteAccount) []string {
	out := make([]string, 0, len(accounts))
	for _, a := range accounts {
		out = append(out, a.ID)
	}
	return out
}

func assertOrder(t *testing.T, cases []rankCase) {
	t.Helper()
	for _, tc := range cases {
		seen := map[float64]string{}
		for _, id := range tc.ExpectedOrder {
			h, known := WeeklyHeadroom(tc.Model, usageOf(tc.Usage)[id])
			if !known {
				h = UnknownHeadroom
			}
			if other, clash := seen[h]; clash {
				// The Mac breaks this tie on an account priority that is per-machine and
				// never crosses the wire, so the two implementations cannot be made to
				// agree on it and a vector would pin an order only one of them keeps.
				t.Fatalf("%s: %s and %s tie at %v headroom — a cross-language vector "+
					"must not contain a tie", tc.Name, other, id, h)
			}
			seen[h] = id
		}
	}
	want := map[string][]string{
		"the most drained eligible account comes first":                    {"nearly", "half", "fresh"},
		"a fable request will not take an account with no fable week left": {"b"},
		"a spent fable week does not stop an opus request":                 {"b", "a"},
		"an unmeasured account sorts mid-pack rather than first or last":   {"drained", "unknown", "fresh"},
		"an account needing re-login is never ranked":                      {"live"},
		"an excluded account is skipped even with headroom":                {"half", "fresh"},
		"ranking is on the weekly window, never the five-hour one":         {"b", "a"},
		"an exhausted five-hour window still makes an account ineligible":  {"b"},
		"a per-minute ceiling never makes an account the wrong choice":     {"a"},
	}
	for _, tc := range cases {
		expected, ok := want[tc.Name]
		if !ok {
			t.Fatalf("no expectation written for %q", tc.Name)
		}
		if !equalStrings(tc.ExpectedOrder, expected) {
			t.Errorf("%s: got %v, want %v", tc.Name, tc.ExpectedOrder, expected)
		}
	}
}

func assertAvailability(t *testing.T, cases []availCase) {
	t.Helper()
	for _, tc := range cases {
		switch tc.Name {
		case "an account with headroom is available now":
			if !tc.ExpectedAvailableAt["a"].Equal(noon) {
				t.Errorf("%s: got %v", tc.Name, tc.ExpectedAvailableAt["a"])
			}
		case "every blocking window has to clear, so the last reset wins":
			if !tc.ExpectedAvailableAt["a"].Equal(noon.Add(6 * time.Hour)) {
				t.Errorf("%s: got %v", tc.Name, tc.ExpectedAvailableAt["a"])
			}
		case "a blocked window with no reset makes the answer unknowable":
			if !equalStrings(tc.ExpectedUnknowable, []string{"a"}) {
				t.Errorf("%s: got %v", tc.Name, tc.ExpectedUnknowable)
			}
			if tc.ExpectedSoonestID != nil {
				t.Errorf("%s: no account can serve it, so there is no soonest", tc.Name)
			}
		case "the soonest is the earliest of several, and an unknowable one is passed over":
			if tc.ExpectedSoonestID == nil || *tc.ExpectedSoonestID != "soon" {
				t.Errorf("%s: got %v", tc.Name, tc.ExpectedSoonestID)
			}
			if !equalStrings(tc.ExpectedUnknowable, []string{"never"}) {
				t.Errorf("%s: unknowable %v", tc.Name, tc.ExpectedUnknowable)
			}
		default:
			t.Fatalf("no expectation written for %q", tc.Name)
		}
	}
}

func assertFolding(t *testing.T, cases []foldCase) {
	t.Helper()
	find := func(s vecSnapshot, kind wire.WindowKind) (wire.UsageWindow, bool) {
		for _, w := range s.Windows {
			if w.Kind == kind {
				return w, true
			}
		}
		return wire.UsageWindow{}, false
	}
	for _, tc := range cases {
		session, hasSession := find(tc.Expected, wire.WindowSession)
		scoped, hasScoped := find(tc.Expected, wire.WindowWeeklyScoped)
		switch tc.Name {
		case "a late answer does not lower a header-fresh window":
			if session.Percent != 36 {
				t.Errorf("%s: session %v", tc.Name, session.Percent)
			}
			if !tc.Expected.FetchedAt.Equal(noon) {
				t.Errorf("%s: fetchedAt moved to %v", tc.Name, tc.Expected.FetchedAt)
			}
		case "a late answer still carries the windows only it reports":
			if session.Percent != 36 || !hasScoped || scoped.Percent != 17 {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
			if !tc.Expected.LastEndpointFetch.Equal(noon.Add(-280 * time.Second)) {
				t.Errorf("%s: endpoint stamp %v", tc.Name, tc.Expected.LastEndpointFetch)
			}
		case "a late answer drops a per-model window it no longer reports":
			if hasScoped {
				t.Errorf("%s: kept a window the endpoint stopped reporting", tc.Name)
			}
			if session.Percent != 36 {
				t.Errorf("%s: session %v", tc.Name, session.Percent)
			}
		case "an answer older than the last endpoint read changes nothing":
			if !hasScoped || scoped.Percent != 50 || session.Percent != 36 {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
		case "a current answer replaces what is held, including a window that is gone":
			if session.Percent != 99 || hasScoped {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
		case "with nothing held the answer is taken whole":
			if !hasSession || session.Percent != 12 ||
				!tc.Expected.LastEndpointFetch.Equal(noon) {
				t.Errorf("%s: %+v", tc.Name, tc.Expected)
			}
		default:
			t.Fatalf("no expectation written for %q", tc.Name)
		}
	}
}

func assertHeaderFolding(t *testing.T, cases []headerFoldCase) {
	t.Helper()
	percent := func(s vecSnapshot, kind wire.WindowKind) (float64, bool) {
		for _, w := range s.Windows {
			if w.Kind == kind {
				return w.Percent, true
			}
		}
		return 0, false
	}
	for _, tc := range cases {
		session, hasSession := percent(tc.Expected, wire.WindowSession)
		weekly, hasWeekly := percent(tc.Expected, wire.WindowWeeklyAll)
		scoped, hasScoped := percent(tc.Expected, wire.WindowWeeklyScoped)
		switch tc.Name {
		case "a response naming only the five-hour window leaves the weekly one alone":
			if session != 55 {
				t.Errorf("%s: session %v", tc.Name, session)
			}
			if !hasWeekly || weekly != 96 {
				t.Errorf("%s: the weekly window was dropped (%v, %v)", tc.Name, hasWeekly, weekly)
			}
			// The endpoint's own window is never a header's business either way.
			if !hasScoped || scoped != 40 {
				t.Errorf("%s: the per-model window was dropped", tc.Name)
			}
		case "both windows are replaced when both are reported":
			if session != 55 || weekly != 97 || scoped != 40 {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
		case "a response with no rate-limit headers changes nothing at all":
			if session != 10 || weekly != 96 || scoped != 40 {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
			// Not even the stamp: bumping it makes the next genuinely fresher endpoint
			// answer look late, and FoldEndpoint would then refuse it.
			if !tc.Expected.FetchedAt.Equal(noon.Add(-5 * time.Minute)) {
				t.Errorf("%s: the stamp moved to %v", tc.Name, tc.Expected.FetchedAt)
			}
		case "with nothing held the headers are taken as they are":
			if !hasSession || session != 12 {
				t.Errorf("%s: %+v", tc.Name, tc.Expected.Windows)
			}
		default:
			t.Fatalf("no expectation written for %q", tc.Name)
		}
	}
}

func assertHeaders(t *testing.T, cases []headerCase) {
	t.Helper()
	for _, tc := range cases {
		switch tc.Name {
		case "both unified windows, as fractions of the limit":
			if len(tc.ExpectedWindows) != 2 || tc.ExpectedWindows[0].Percent != 74 ||
				tc.ExpectedWindows[1].Percent != 11 {
				t.Errorf("%s: %+v", tc.Name, tc.ExpectedWindows)
			}
			// Every window a header can carry must be one the fold treats as
			// header-reported, or the endpoint would keep overwriting it.
			for _, w := range tc.ExpectedWindows {
				if !ReportedByHeaders(w) {
					t.Errorf("%s: %s is parsed from a header but not treated as one",
						tc.Name, w.Kind)
				}
			}
		case "no rate-limit headers at all", "a 429 is a refusal whatever the headers say",
			"so is a 200 the server marked rejected", "an allowed status is not a refusal":
			if len(tc.ExpectedWindows) != 0 {
				t.Errorf("%s: %+v", tc.Name, tc.ExpectedWindows)
			}
		case "a utilization with no reset beside it is still a window":
			if len(tc.ExpectedWindows) != 1 || tc.ExpectedWindows[0].ResetsAt != nil {
				t.Errorf("%s: %+v", tc.Name, tc.ExpectedWindows)
			}
		default:
			t.Fatalf("no expectation written for %q", tc.Name)
		}
		wantLimited := tc.StatusCode == 429 ||
			tc.Headers["anthropic-ratelimit-unified-status"] == "rejected"
		if tc.ExpectedLimited != wantLimited {
			t.Errorf("%s: rateLimited %v", tc.Name, tc.ExpectedLimited)
		}
	}
}

func assertResets(t *testing.T, cases []resetCase) {
	t.Helper()
	for _, tc := range cases {
		switch tc.Name {
		case "a far upstream reset is shortened to when an account frees up",
			"with no upstream reset the header is added":
			if !tc.Changed {
				t.Fatalf("%s: refused to rewrite", tc.Name)
			}
			last := tc.Expected[len(tc.Expected)-1]
			if last.Name != resetHeader || last.Value != "1789480800" {
				t.Errorf("%s: %+v", tc.Name, tc.Expected)
			}
			for _, h := range tc.Expected[:len(tc.Expected)-1] {
				if h.Name == resetHeader || h.Name == "Anthropic-RateLimit-Unified-Reset" {
					t.Errorf("%s: the old reset survived", tc.Name)
				}
			}
		case "a reset sooner than our answer is left alone",
			"an answer of now is never written over a real reset":
			if tc.Changed {
				t.Errorf("%s: lengthened a wait", tc.Name)
			}
		default:
			t.Fatalf("no expectation written for %q", tc.Name)
		}
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// A nil slice marshals as `null`, which the Swift side decodes into `[UsageWindow]` as a
// failure rather than as "none". Every list in a vector is written as a list.
func windowList(windows []wire.UsageWindow) []wire.UsageWindow {
	if windows == nil {
		return []wire.UsageWindow{}
	}
	return windows
}

func writeVector(t *testing.T, name string, payload any) {
	t.Helper()
	encoded, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')
	path := filepath.Join("..", "..", "testdata", "rules", name)
	if os.Getenv("UPDATE_FIXTURES") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	onDisk, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s missing — run UPDATE_FIXTURES=1 go test ./internal/rules/: %v", name, err)
	}
	if string(onDisk) != string(encoded) {
		t.Errorf("%s has drifted from what this package computes.\n"+
			"The Swift suite decodes this file; regenerate with "+
			"UPDATE_FIXTURES=1 go test ./internal/rules/ and check `make test` still passes.",
			name)
	}
}
