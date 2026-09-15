package rules

import (
	"math"
	"strconv"
	"strings"
	"time"

	"ccmuxd/wire"
)

const resetHeader = "anthropic-ratelimit-unified-reset"

// Roughly the year 5138. Past this a header is not a timestamp, and converting it would
// land on a date so far out that it silently inverts every comparison.
const maxEpochSeconds = 1e11

// WindowsFromHeaders reads the anthropic-ratelimit-unified-* headers that ride along on
// every inference response. Free and exact for the 5-hour and weekly windows; per-model
// windows never appear here, so those still need the usage endpoint.
//
// Header names must already be lower-cased, which the proxy does once while it walks the
// response rather than every reader rebuilding a folded copy.
func WindowsFromHeaders(headers map[string]string) []wire.UsageWindow {
	var out []wire.UsageWindow
	read := func(prefix string, kind wire.WindowKind, label string) {
		raw, ok := headers["anthropic-ratelimit-unified-"+prefix+"-utilization"]
		if !ok {
			return
		}
		fraction, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			return
		}
		window := wire.UsageWindow{
			Kind: kind, Label: label,
			// The header is a fraction of the limit: 0.35 is 35%.
			Percent: fraction * 100,
		}
		if at, ok := epoch(headers["anthropic-ratelimit-unified-"+prefix+"-reset"]); ok {
			window.ResetsAt = &wire.Time{Time: at}
		}
		out = append(out, window)
	}
	read("5h", wire.WindowSession, "5-hour")
	read("7d", wire.WindowWeeklyAll, "Weekly")
	return out
}

func epoch(raw string) (time.Time, bool) {
	if raw == "" {
		return time.Time{}, false
	}
	seconds, err := strconv.ParseFloat(raw, 64)
	// The fraction is kept: truncating it moves the moment by up to a second and flips
	// ShorteningReset's "is the upstream reset already sooner" comparison, so the two
	// implementations would answer differently from the same response. A value too large
	// to be a date is not one.
	if err != nil || math.IsNaN(seconds) || math.Abs(seconds) > maxEpochSeconds {
		return time.Time{}, false
	}
	whole, fraction := math.Modf(seconds)
	return time.Unix(int64(whole), int64(fraction*float64(time.Second))).UTC(), true
}

// IsRateLimited reports whether the server refused this request for hitting a limit.
// Header names must already be lower-cased.
func IsRateLimited(headers map[string]string, statusCode int) bool {
	return statusCode == 429 || headers["anthropic-ratelimit-unified-status"] == "rejected"
}

// Header is one response header, kept as a slice rather than a map because order and
// repeats have to survive the trip back to Claude Code.
type Header struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// ShorteningReset rewrites anthropic-ratelimit-unified-reset to the moment some account
// frees up, so Claude Code knows there is a point in waiting. It refuses to wait at all
// when the reset is more than 24 hours out, so the header has to describe the soonest
// moment *any* account is free, not just the one that refused.
//
// Only ever shortens. Our view of a per-model weekly window can be stale — those never
// appear in response headers — and AvailableAt reports "now" when it sees nothing
// blocked. Writing that over a correct far-future reset would make Claude Code retry
// immediately, in a loop, burning a request on every account each time.
func ShorteningReset(headers []Header, to time.Time, now time.Time) ([]Header, bool) {
	if to.Sub(now) <= 30*time.Second {
		return nil, false
	}
	for _, header := range headers {
		if !strings.EqualFold(header.Name, resetHeader) {
			continue
		}
		if at, ok := epoch(header.Value); ok && !at.After(to) {
			return nil, false
		}
	}
	out := make([]Header, 0, len(headers)+1)
	for _, header := range headers {
		if !strings.EqualFold(header.Name, resetHeader) {
			out = append(out, header)
		}
	}
	return append(out, Header{resetHeader, strconv.FormatInt(to.Unix(), 10)}), true
}
