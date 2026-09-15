package ledger

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"ccmuxd/wire"
)

// The price table exists twice, here and in Sources/CCMuxKit/Policy/Pricing.swift, and a
// figure that disagrees between them misbooks real money on the Stats page. These vectors
// are decoded by Tests/CCMuxKitTests/RuleVectorTests.swift.
//
// Regenerate with: UPDATE_FIXTURES=1 go test ./internal/ledger/

type priceCase struct {
	Name    string     `json:"name"`
	Model   string     `json:"model"`
	At      wire.Time  `json:"at"`
	Usage   TokenUsage `json:"usage"`
	Priced  bool       `json:"priced"`
	CostUSD float64    `json:"costUSD"`
	// What the model id resolves to in the table, which is the subtle half.
	Normalized string `json:"normalized"`
}

func priceCases() []priceCase {
	day := func(text string) wire.Time {
		at, err := time.Parse(time.RFC3339, text)
		if err != nil {
			panic(err)
		}
		return wire.Time{Time: at}
	}
	now := day("2026-09-15T12:00:00Z")
	mixed := TokenUsage{Input: 1000, Output: 500, CacheRead: 20000,
		CacheWrite5m: 3000, CacheWrite1h: 250}

	cases := []priceCase{
		{Name: "opus 5, every token kind at once", Model: "claude-opus-5", At: now, Usage: mixed},
		{Name: "haiku 4.5", Model: "claude-haiku-4-5", At: now, Usage: mixed},
		{Name: "sonnet 4.6", Model: "claude-sonnet-4-6", At: now, Usage: mixed},
		// Fable 5.1 is the one model whose cache read is not a flat tenth of input.
		{Name: "fable 5.1, with its own cache-read rate", Model: "claude-fable-5-1",
			At: now, Usage: mixed},
		// Mythos 5.1 matches Fable on input and output but deliberately does NOT inherit
		// the cheaper cache read.
		{Name: "mythos 5.1 does not inherit fable's cache read", Model: "claude-mythos-5-1",
			At: now, Usage: mixed},
		// A dated snapshot inherits its parent's price.
		{Name: "a dated snapshot inherits its model's price", Model: "claude-haiku-4-5-20251001",
			At: now, Usage: mixed},
		// A different model with a similar name does not.
		{Name: "a similar name is not a snapshot", Model: "claude-sonnet-5-2",
			At: now, Usage: mixed},
		// Fable 5.1 is not a snapshot of Fable 5, so it must not inherit either.
		{Name: "a point release is not a snapshot", Model: "claude-fable-5-2",
			At: now, Usage: mixed},
		{Name: "the context marker is stripped", Model: "claude-opus-5[1m]",
			At: now, Usage: mixed},
		{Name: "an unknown model is not guessed at", Model: "claude-unheard-of-9",
			At: now, Usage: mixed},
		// Sonnet 5's promotional rates run through the end of the named day.
		{Name: "sonnet 5 inside its promotional window", Model: "claude-sonnet-5",
			At: day("2026-08-15T00:00:00Z"), Usage: mixed},
		{Name: "sonnet 5 on the last day of the promotion", Model: "claude-sonnet-5",
			At: day("2026-08-31T23:59:59Z"), Usage: mixed},
		{Name: "sonnet 5 after the promotion", Model: "claude-sonnet-5",
			At: day("2026-09-02T00:00:00Z"), Usage: mixed},
		{Name: "no tokens at all costs nothing", Model: "claude-opus-5", At: now,
			Usage: TokenUsage{}},
		{Name: "output only", Model: "claude-opus-5", At: now,
			Usage: TokenUsage{Output: 1_000_000}},
	}
	for i := range cases {
		cases[i].CostUSD, cases[i].Priced = Cost(cases[i].Model, cases[i].Usage,
			cases[i].At.Time)
		cases[i].Normalized = Normalize(cases[i].Model)
	}
	return cases
}

func TestPricingVectors(t *testing.T) {
	cases := priceCases()
	byName := map[string]priceCase{}
	for _, tc := range cases {
		byName[tc.Name] = tc
	}

	// The rules the table encodes, asserted rather than merely recorded.
	if byName["an unknown model is not guessed at"].Priced {
		t.Error("an unknown model was priced")
	}
	for _, name := range []string{"a similar name is not a snapshot",
		"a point release is not a snapshot"} {
		if byName[name].Priced {
			t.Errorf("%s: inherited a price it should not have", name)
		}
	}
	if got := byName["a dated snapshot inherits its model's price"]; !got.Priced ||
		got.Normalized != "claude-haiku-4-5" {
		t.Errorf("a dated snapshot did not inherit: %+v", got)
	}
	if got := byName["the context marker is stripped"]; got.Normalized != "claude-opus-5" {
		t.Errorf("the [1m] marker was not stripped: %q", got.Normalized)
	}
	// Fable 5.1's cheaper cache read has to make it cost less than Mythos 5.1 on the same
	// tokens, which is the whole reason the override exists.
	fable := byName["fable 5.1, with its own cache-read rate"].CostUSD
	mythos := byName["mythos 5.1 does not inherit fable's cache read"].CostUSD
	if !(fable < mythos) {
		t.Errorf("fable %v should cost less than mythos %v on identical tokens", fable, mythos)
	}
	// The promotion applies through the end of the named day and not after it.
	inside := byName["sonnet 5 inside its promotional window"].CostUSD
	lastDay := byName["sonnet 5 on the last day of the promotion"].CostUSD
	after := byName["sonnet 5 after the promotion"].CostUSD
	if inside != lastDay {
		t.Errorf("the last day of the promotion priced differently: %v vs %v", lastDay, inside)
	}
	if !(inside < after) {
		t.Errorf("the promotion did not end: %v then %v", inside, after)
	}
	if byName["no tokens at all costs nothing"].CostUSD != 0 {
		t.Error("zero tokens cost something")
	}
	// One million output tokens of Opus 5 is exactly the listed rate.
	if got := byName["output only"].CostUSD; got != 25 {
		t.Errorf("1M opus output = %v, want 25", got)
	}

	encoded, err := json.MarshalIndent(map[string]any{"cases": cases}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')
	path := filepath.Join("..", "..", "testdata", "rules", "pricing.json")
	if os.Getenv("UPDATE_FIXTURES") == "1" {
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	onDisk, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("pricing.json missing — run UPDATE_FIXTURES=1 go test ./internal/ledger/: %v", err)
	}
	if string(onDisk) != string(encoded) {
		t.Error("pricing.json has drifted from what this package computes. " +
			"Regenerate with UPDATE_FIXTURES=1 go test ./internal/ledger/ and check " +
			"`make test` still passes.")
	}
}
