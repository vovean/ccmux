package ledger

import (
	"strings"
	"time"
)

// First-party Claude API list prices, per million tokens. Kept as data so a price change
// is a one-line edit rather than a hunt through the cost maths. Must stay in step with
// Sources/CCMuxKit/Policy/Pricing.swift; testdata/rules/pricing.json pins the two.
type ModelPrice struct {
	InputPerMTok  float64
	OutputPerMTok float64
	// Promotional rates, in force through the end of the day named by IntroEndsAfter.
	IntroInputPerMTok  float64
	IntroOutputPerMTok float64
	IntroEndsAfter     string
	// Set where a cache read stopped being a flat tenth of input.
	CacheReadPerMTok float64
}

// A 5-minute cache write costs 1.25x input and a 1-hour write 2x on every model. A cache
// read is a tenth of input except where CacheReadPerMTok says otherwise — that stopped
// being uniform with Claude Fable 5.1.
const (
	cacheWrite5mMultiplier = 1.25
	cacheWrite1hMultiplier = 2.0
	cacheReadMultiplier    = 0.1
)

var table = map[string]ModelPrice{
	// Fable 5.1 is not a dated snapshot of Fable 5, so normalize deliberately refuses to
	// inherit its price — the entry has to be explicit or the model bills as unpriced.
	"claude-fable-5-1": {InputPerMTok: 10, OutputPerMTok: 50, CacheReadPerMTok: 0.25},
	"claude-fable-5":   {InputPerMTok: 10, OutputPerMTok: 50},
	// No cache-read override: Mythos 5.1 matches Fable 5.1 on input and output, but
	// whether it shares the cheaper cache read is unconfirmed, and the uniform tenth is
	// the safer guess to bill against.
	"claude-mythos-5-1": {InputPerMTok: 10, OutputPerMTok: 50},
	"claude-mythos-5":   {InputPerMTok: 10, OutputPerMTok: 50},
	"claude-opus-5":     {InputPerMTok: 5, OutputPerMTok: 25},
	"claude-opus-4-8":   {InputPerMTok: 5, OutputPerMTok: 25},
	"claude-opus-4-7":   {InputPerMTok: 5, OutputPerMTok: 25},
	"claude-opus-4-6":   {InputPerMTok: 5, OutputPerMTok: 25},
	"claude-sonnet-5": {InputPerMTok: 3, OutputPerMTok: 15, IntroInputPerMTok: 2,
		IntroOutputPerMTok: 10, IntroEndsAfter: "2026-08-31"},
	"claude-sonnet-4-6": {InputPerMTok: 3, OutputPerMTok: 15},
	"claude-haiku-4-5":  {InputPerMTok: 1, OutputPerMTok: 5},
}

func (p ModelPrice) rates(on time.Time) (float64, float64) {
	if p.IntroInputPerMTok == 0 || p.IntroEndsAfter == "" {
		return p.InputPerMTok, p.OutputPerMTok
	}
	end, err := time.ParseInLocation("2006-01-02", p.IntroEndsAfter, time.UTC)
	if err != nil || on.After(end.Add(24*time.Hour)) {
		return p.InputPerMTok, p.OutputPerMTok
	}
	return p.IntroInputPerMTok, p.IntroOutputPerMTok
}

// Normalize strips the decorations a response can carry — a date suffix, a [1m] context
// marker — so "claude-haiku-4-5-20251001" finds the "claude-haiku-4-5" entry.
func Normalize(modelID string) string {
	id := strings.ToLower(modelID)
	if bracket := strings.IndexByte(id, '['); bracket >= 0 {
		id = id[:bracket]
	}
	if _, ok := table[id]; ok {
		return id
	}
	// Only a dated snapshot of a known model inherits its price. A prefix match alone
	// would quietly bill a future "claude-sonnet-5-2" at Sonnet 5's rates — including its
	// promotional ones — instead of reporting an unknown model.
	best := ""
	for key := range table {
		suffix, ok := strings.CutPrefix(id, key+"-")
		if !ok || len(suffix) != 8 {
			continue
		}
		digits := true
		for _, r := range suffix {
			if r < '0' || r > '9' {
				digits = false
				break
			}
		}
		if digits && len(key) > len(best) {
			best = key
		}
	}
	if best != "" {
		return best
	}
	return id
}

func Price(modelID string) (ModelPrice, bool) {
	price, ok := table[Normalize(modelID)]
	return price, ok
}

// Cost is the dollars one request cost, and false when the model is not in the table — a
// wrong number here is worse than an absent one, so an unknown model is not guessed at.
func Cost(model string, usage TokenUsage, on time.Time) (float64, bool) {
	price, ok := Price(model)
	if !ok {
		return 0, false
	}
	inputRate, outputRate := price.rates(on)
	perToken := inputRate / 1_000_000
	cacheReadPerToken := perToken * cacheReadMultiplier
	if price.CacheReadPerMTok != 0 {
		cacheReadPerToken = price.CacheReadPerMTok / 1_000_000
	}
	return perToken*float64(usage.Input) +
		outputRate/1_000_000*float64(usage.Output) +
		cacheReadPerToken*float64(usage.CacheRead) +
		perToken*cacheWrite5mMultiplier*float64(usage.CacheWrite5m) +
		perToken*cacheWrite1hMultiplier*float64(usage.CacheWrite1h), true
}
