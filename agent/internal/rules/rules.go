// Package rules decides which account serves a request, and folds the two sources that
// report how much of each account is left.
//
// Ported from the Mac's PolicyEngine, ModelRouting, UsageParser and UsageSnapshot.folding.
// The two implementations are kept honest by the vectors in agent/testdata/rules, which
// this package's tests generate and the Swift suite decodes.
package rules

import (
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"ccmuxd/wire"
)

// UnknownHeadroom is where an account with no usage data sorts. Mid-pack on purpose: it
// is a gamble either way, and the first response corrects it.
const UnknownHeadroom = 50.0

// Snapshot is one account's windows plus when each of the two sources last spoke.
// Held in memory only. It is rebuilt from ccmuxd on start rather than persisted, so it
// carries no JSON tags: a time.Time here would marshal with a precision the Mac's
// decoder rejects, and a zero one would read back as a year-1 date rather than "never".
type Snapshot struct {
	Windows []wire.UsageWindow
	// When any source last updated these numbers, a response header included.
	FetchedAt time.Time
	// When the usage endpoint last answered. Separate from FetchedAt because headers
	// refresh the 5-hour and weekly windows but never the per-model ones, so scheduling
	// off FetchedAt would let a busy session suppress the endpoint and freeze them.
	LastEndpointFetch time.Time
}

// ReportedByHeaders says whether a proxied response header can carry this window. The
// per-model ones cannot: they exist solely in the usage endpoint's answer.
func ReportedByHeaders(w wire.UsageWindow) bool {
	switch w.Kind {
	case wire.WindowSession, wire.WindowWeeklyAll:
		return true
	default:
		return false
	}
}

// Governs reports whether a per-model weekly window applies to this model id.
//
// Compared with separators and case removed, so a display name like "Sonnet 4.5" still
// matches claude-sonnet-4-5. A name shorter than three characters is ignored rather than
// risk matching every model.
func Governs(w wire.UsageWindow, modelID string) bool {
	if w.Kind != wire.WindowWeeklyScoped || w.ModelName == nil {
		return false
	}
	needle := normalize(*w.ModelName)
	// Characters, not bytes: the Mac counts these as Characters, and a two-character
	// non-ASCII display name is several bytes.
	if utf8.RuneCountInString(needle) < 3 {
		return false
	}
	return strings.Contains(normalize(modelID), needle)
}

func normalize(text string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(text) {
		// IsNumber rather than IsDigit: the Mac's Character.isNumber accepts every
		// numeric scalar, not only the decimal-digit category.
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// BindingWindows are the windows that actually gate a request for this model: the 5-hour
// and weekly-all windows always, plus that model's own weekly window when the plan has
// one. A scoped window for a different model is deliberately excluded — a spent Fable
// week does not stop an Opus request. `other` covers the per-minute API ceilings, which
// refill continuously: they throttle a request, they never make an account the wrong
// choice.
func BindingWindows(modelID string, snapshot *Snapshot) []wire.UsageWindow {
	if snapshot == nil {
		return nil
	}
	var out []wire.UsageWindow
	for _, w := range snapshot.Windows {
		switch w.Kind {
		case wire.WindowSession, wire.WindowWeeklyAll:
			out = append(out, w)
		case wire.WindowWeeklyScoped:
			if modelID != "" && Governs(w, modelID) {
				out = append(out, w)
			}
		}
	}
	return out
}

// Headroom on the tightest window gating this model. False when nothing is known.
func Headroom(modelID string, snapshot *Snapshot) (float64, bool) {
	windows := BindingWindows(modelID, snapshot)
	if len(windows) == 0 {
		return 0, false
	}
	lowest := windows[0].Headroom()
	for _, w := range windows[1:] {
		if h := w.Headroom(); h < lowest {
			lowest = h
		}
	}
	return lowest, true
}

// WeeklyHeadroom is what accounts are ranked on. The 5-hour window refills all day, so
// ranking on it would reshuffle the order every few hours without any of the
// subscription actually being used up; the weekly quota is the thing that expires.
func WeeklyHeadroom(modelID string, snapshot *Snapshot) (float64, bool) {
	var weekly []wire.UsageWindow
	for _, w := range BindingWindows(modelID, snapshot) {
		if w.Kind == wire.WindowWeeklyAll || w.Kind == wire.WindowWeeklyScoped {
			weekly = append(weekly, w)
		}
	}
	if len(weekly) == 0 {
		return Headroom(modelID, snapshot)
	}
	lowest := weekly[0].Headroom()
	for _, w := range weekly[1:] {
		if h := w.Headroom(); h < lowest {
			lowest = h
		}
	}
	return lowest, true
}

// CanServe reports whether this account can serve the model right now. An account with
// no usage data is allowed through: the alternative is refusing to use an account we
// simply have not measured, and the response itself will correct us.
func CanServe(modelID string, snapshot *Snapshot) bool {
	headroom, known := Headroom(modelID, snapshot)
	return !known || headroom > 0
}

// AvailableAt is when this account could next serve the model: now if it already can,
// otherwise the reset of whichever gating window is exhausted and resets last. Every
// blocking window has to clear, and a blocked window with no known reset makes the
// answer unknowable, which is reported as false rather than as "now".
func AvailableAt(modelID string, snapshot *Snapshot, now time.Time) (time.Time, bool) {
	windows := BindingWindows(modelID, snapshot)
	if len(windows) == 0 {
		return now, true
	}
	var latest time.Time
	blocked := false
	for _, w := range windows {
		if w.Headroom() > 0 {
			continue
		}
		blocked = true
		if w.ResetsAt == nil || w.ResetsAt.IsZero() {
			return time.Time{}, false
		}
		if w.ResetsAt.Time.After(latest) {
			latest = w.ResetsAt.Time
		}
	}
	if !blocked {
		return now, true
	}
	return latest, true
}

func eligible(account wire.RemoteAccount, excluded map[string]bool) bool {
	return !excluded[account.ID] && account.Health != wire.HealthNeedsRelogin
}

// RankLeastRemaining returns the accounts that can serve this model, least remaining
// first, so one subscription is drained before the next is started on. Three half-used
// subscriptions at the end of the week is wasted quota; one spent and two fresh is not.
//
// Eligibility is the part that must not be relaxed: a Fable request only considers
// accounts with Fable weekly headroom left, never one that merely has general weekly
// headroom.
//
// The Mac breaks a tie on the account's local priority, which does not exist here; the
// label and then the id stand in, so the order is total and two boxes holding the same
// answer rank it the same way.
func RankLeastRemaining(modelID string, accounts []wire.RemoteAccount,
	usage map[string]*Snapshot, excluded map[string]bool) []wire.RemoteAccount {
	var kept []wire.RemoteAccount
	for _, account := range accounts {
		if !eligible(account, excluded) || !CanServe(modelID, usage[account.ID]) {
			continue
		}
		kept = append(kept, account)
	}
	// Computed once per account rather than once per comparison: each call walks the
	// snapshot and allocates, and the fallback path walks it twice.
	headroom := make(map[string]float64, len(kept))
	for _, account := range kept {
		if h, known := WeeklyHeadroom(modelID, usage[account.ID]); known {
			headroom[account.ID] = h
		} else {
			headroom[account.ID] = UnknownHeadroom
		}
	}
	sort.SliceStable(kept, func(i, j int) bool {
		li, lj := headroom[kept[i].ID], headroom[kept[j].ID]
		if li != lj {
			return li < lj
		}
		ni := strings.ToLower(kept[i].DisplayName())
		nj := strings.ToLower(kept[j].DisplayName())
		if ni != nj {
			return ni < nj
		}
		return kept[i].ID < kept[j].ID
	})
	return kept
}

// Pick is the account to use: the most-drained one that can still serve the model.
func Pick(modelID string, accounts []wire.RemoteAccount, usage map[string]*Snapshot,
	excluded map[string]bool) (wire.RemoteAccount, bool) {
	ranked := RankLeastRemaining(modelID, accounts, usage, excluded)
	if len(ranked) == 0 {
		return wire.RemoteAccount{}, false
	}
	return ranked[0], true
}

// SoonestAvailable is the earliest moment any of these accounts could serve the model.
// Excluded accounts are deliberately still considered: this answers "when is it worth
// trying again", and an account skipped for this attempt is available for the next.
func SoonestAvailable(modelID string, accounts []wire.RemoteAccount,
	usage map[string]*Snapshot, now time.Time) (string, time.Time, bool) {
	var bestID string
	var best time.Time
	found := false
	for _, account := range accounts {
		if account.Health == wire.HealthNeedsRelogin {
			continue
		}
		at, known := AvailableAt(modelID, usage[account.ID], now)
		if !known {
			continue
		}
		if !found || at.Before(best) {
			bestID, best, found = account.ID, at, true
		}
	}
	return bestID, best, found
}

// FoldEndpoint merges an answer from the usage endpoint into what is held.
//
// A delegated answer is served from ccmuxd's cache and can arrive minutes stale, while
// headers refresh the 5-hour and weekly windows seconds after every request. Taking it
// wholesale is what made those two travel backwards.
func FoldEndpoint(windows []wire.UsageWindow, previous *Snapshot,
	observedAt time.Time) Snapshot {
	if previous == nil || !observedAt.Before(previous.FetchedAt) {
		// At least as fresh as anything held, so it is authoritative — a window it no
		// longer reports is one the account no longer has.
		return Snapshot{Windows: windows, FetchedAt: observedAt, LastEndpointFetch: observedAt}
	}
	if observedAt.Before(previous.LastEndpointFetch) {
		// Older than the last endpoint read as well, so it knows nothing newer at all.
		return *previous
	}
	// It is still the only source for the per-model windows, and it owns whether those
	// exist: holding one it has stopped reporting would pin that model at its last
	// percent and route every request for it off a healthy account forever.
	merged := make([]wire.UsageWindow, 0, len(previous.Windows)+len(windows))
	for _, w := range previous.Windows {
		if ReportedByHeaders(w) {
			merged = append(merged, w)
		}
	}
	for _, w := range windows {
		if !ReportedByHeaders(w) {
			merged = append(merged, w)
		}
	}
	return Snapshot{
		Windows:   merged,
		FetchedAt: previous.FetchedAt,
		// Moves even though the snapshot's own stamp does not, or the poller would think
		// it had never read the endpoint and never back off.
		LastEndpointFetch: observedAt,
	}
}

// FoldHeaders merges windows read off a response into what is held.
//
// An upsert by window id, not a replacement of everything a header could carry: a
// response that mentions only the 5-hour window says nothing about the weekly one, and
// dropping the weekly window there would make an exhausted account look like the
// freshest one in the pool. A response with no rate-limit headers at all changes
// nothing, not even the timestamp — bumping it would make the next genuinely fresher
// endpoint answer look late and be refused.
//
// Reordering between two header observations is unguarded, exactly as on the Mac: the
// next response corrects it, and a guard here would diverge the two implementations for
// a wobble that lasts one request.
func FoldHeaders(windows []wire.UsageWindow, previous *Snapshot,
	observedAt time.Time) Snapshot {
	if len(windows) == 0 {
		if previous == nil {
			return Snapshot{FetchedAt: observedAt}
		}
		return *previous
	}
	if previous == nil {
		return Snapshot{Windows: windows, FetchedAt: observedAt}
	}
	merged := append([]wire.UsageWindow(nil), previous.Windows...)
	for _, window := range windows {
		replaced := false
		for i := range merged {
			if merged[i].ID() == window.ID() {
				merged[i] = window
				replaced = true
				break
			}
		}
		if !replaced {
			merged = append(merged, window)
		}
	}
	return Snapshot{
		Windows:           merged,
		FetchedAt:         observedAt,
		LastEndpointFetch: previous.LastEndpointFetch,
	}
}
