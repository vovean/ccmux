// Package ledger counts tokens minute by minute on their way to the account server.
//
// A minute is held open while it is still running and handed over only once it has
// ended. That is what makes a bucket immutable the moment it leaves this box, which in
// turn is what lets the server upsert a re-send instead of adding it twice — the whole
// retry story rests on it.
//
// Which is also why a shutdown does not flush the open minute: the agent is restarted
// while its sessions keep running, and a half-minute sent early would be replaced by the
// half recorded after the restart rather than added to it. Open minutes go to the spool
// alongside the closed ones and come back still open.
package ledger

import (
	"encoding/json"
	"os"
	"sort"
	"sync"
	"time"

	"ccmuxd/wire"
)

// TokenUsage is what one response cost. Mirrors proxy.TokenUsage; kept separate so the
// ledger does not depend on the proxy.
type TokenUsage struct {
	Input        int `json:"input"`
	Output       int `json:"output"`
	CacheRead    int `json:"cacheRead"`
	CacheWrite5m int `json:"cacheWrite5m"`
	CacheWrite1h int `json:"cacheWrite1h"`
}

// Identity is everything a bucket needs to name itself, read once per request from state
// that disappears when the session ends.
type Identity struct {
	SessionID          string
	SessionName        string
	AccountID          string
	AccountFingerprint string
	AccountLabel       string
	Kind               wire.AccountKind
	Model              string
	// Set when the token counts are known to be partial. The bucket then carries no cost
	// rather than one computed from numbers we know are short.
	Unpriced bool
}

// slot is the bucket key. The account belongs in the key, not in the payload: a session
// moves to another account when one refuses, and that happens mid-minute on the same
// model — so without it the whole minute would be booked to whichever account served
// last. The minute is seconds since the epoch rather than a time.Time, which carries a
// monotonic reading and a location and so does not compare reliably as a map key.
type slot struct {
	MinuteUnix int64
	SessionID  string
	AccountID  string
	Model      string
}

const (
	// Bytes, not characters, and stricter than the server's own 256-rune ceiling on
	// purpose: a request is capped in bytes, and 256 characters of Cyrillic or one
	// emoji-heavy label is several times its length in UTF-8.
	MaxFieldBytes = 256
	// Past this the oldest go. A box that has not reached the server in days is not going
	// to be caught up by keeping more, and this is what bounds the spool file.
	MaxPending = 10_000
	// A ceiling on the buckets in one push, so a backlog drains over several ticks rather
	// than being refused on every one of them forever.
	MaxPerPush = 400
	// And a ceiling on its encoded size, which is what the server actually bounds: it
	// caps a request body at 1 MiB. Counting buckets is not enough — the fields inside
	// one are user-supplied, so the only honest bound is the measured length.
	MaxPushBytes = 512 * 1024
)

type Ledger struct {
	mu      sync.Mutex
	open    map[slot]wire.UsageBucket
	pending []wire.UsageBucket
	// Set by every mutation and cleared by TakeSpool, so a tick that changed nothing does
	// not rewrite the file.
	dirty bool
}

func New() *Ledger { return &Ledger{open: map[slot]wire.UsageBucket{}} }

func Minute(at time.Time) time.Time { return at.UTC().Truncate(time.Minute) }

func clamp(value string) string {
	if len(value) <= MaxFieldBytes {
		return value
	}
	bytes := 0
	for index, r := range value {
		width := len(string(r))
		if bytes+width > MaxFieldBytes {
			return value[:index]
		}
		bytes += width
	}
	return value
}

// Record folds one request into the minute it landed in.
//
// Priced here rather than at send time so a later edit to the price table cannot rewrite
// what something already cost. Runs for every account, subscription included — those pay
// in quota rather than dollars, and the page says as much.
func (l *Ledger) Record(usage TokenUsage, identity Identity, at time.Time) {
	minute := Minute(at)
	key := slot{
		MinuteUnix: minute.Unix(),
		SessionID:  clamp(identity.SessionID),
		AccountID:  clamp(identity.AccountID),
		Model:      clamp(identity.Model),
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	bucket, found := l.open[key]
	if !found {
		bucket = wire.UsageBucket{
			Minute:    wire.Time{Time: minute},
			SessionID: key.SessionID,
			AccountID: key.AccountID,
			Model:     key.Model,
		}
	}
	// Refreshed on every request: a session renamed mid-minute should carry its new name,
	// and the server takes the newest bucket's identity for the whole line.
	bucket.SessionName = clamp(identity.SessionName)
	if identity.AccountFingerprint != "" {
		bucket.AccountFingerprint = wire.Ptr(clamp(identity.AccountFingerprint))
	} else {
		bucket.AccountFingerprint = nil
	}
	bucket.AccountLabel = clamp(identity.AccountLabel)
	bucket.Kind = identity.Kind
	bucket.Requests++
	bucket.Input += usage.Input
	bucket.Output += usage.Output
	bucket.CacheRead += usage.CacheRead
	bucket.CacheWrite5m += usage.CacheWrite5m
	bucket.CacheWrite1h += usage.CacheWrite1h
	// The model is part of the slot, so every request in one bucket prices the same way:
	// either they all carry a cost or none of them do.
	if cost, priced := Cost(key.Model, usage, at); priced && !identity.Unpriced {
		running := 0.0
		if bucket.CostUSD != nil {
			running = *bucket.CostUSD
		}
		bucket.CostUSD = wire.Ptr(running + cost)
	} else {
		bucket.CostUSD = nil
	}
	l.open[key] = bucket
	l.dirty = true
}

// CloseElapsed moves every minute that has ended into the queue.
func (l *Ledger) CloseElapsed(now time.Time) int {
	boundary := Minute(now).Unix()
	l.mu.Lock()
	defer l.mu.Unlock()
	var done []slot
	for key := range l.open {
		if key.MinuteUnix < boundary {
			done = append(done, key)
		}
	}
	if len(done) == 0 {
		return 0
	}
	// Sorted, because a map has no order and the queue is drained from the front:
	// without this the ceiling below would throw away an arbitrary bucket instead of the
	// oldest one.
	sort.Slice(done, func(i, j int) bool {
		if done[i].MinuteUnix != done[j].MinuteUnix {
			return done[i].MinuteUnix < done[j].MinuteUnix
		}
		if done[i].SessionID != done[j].SessionID {
			return done[i].SessionID < done[j].SessionID
		}
		if done[i].AccountID != done[j].AccountID {
			return done[i].AccountID < done[j].AccountID
		}
		return done[i].Model < done[j].Model
	})
	for _, key := range done {
		l.pending = append(l.pending, l.open[key])
		delete(l.open, key)
	}
	if len(l.pending) > MaxPending {
		l.pending = append([]wire.UsageBucket(nil), l.pending[len(l.pending)-MaxPending:]...)
	}
	l.dirty = true
	return len(done)
}

// Batch is the front of the queue, bounded for one request.
func (l *Ledger) Batch() []wire.UsageBucket {
	l.mu.Lock()
	defer l.mu.Unlock()
	end := min(len(l.pending), MaxPerPush)
	return fit(append([]wire.UsageBucket(nil), l.pending[:end]...), MaxPushBytes)
}

// fit halves the batch until it encodes small enough. One bucket always goes, however
// big: refusing to send it would wedge the queue behind it forever.
func fit(buckets []wire.UsageBucket, budget int) []wire.UsageBucket {
	for len(buckets) > 1 && encodedSize(buckets) > budget {
		buckets = buckets[:len(buckets)/2]
	}
	return buckets
}

func encodedSize(buckets []wire.UsageBucket) int {
	encoded, err := json.Marshal(buckets)
	if err != nil {
		return int(^uint(0) >> 1)
	}
	return len(encoded)
}

// Acknowledge drops the buckets a push carried away, by identity.
//
// Not by count: the queue is trimmed from the front when it hits its ceiling, and a push
// over a slow link outlives a tick — so a count taken before the push can name buckets
// that were never sent, and acknowledging it would delete them unsent.
func (l *Ledger) Acknowledge(sent []wire.UsageBucket) {
	if len(sent) == 0 {
		return
	}
	done := make(map[slot]bool, len(sent))
	for _, bucket := range sent {
		done[slotOf(bucket)] = true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	kept := l.pending[:0]
	for _, bucket := range l.pending {
		if !done[slotOf(bucket)] {
			kept = append(kept, bucket)
		}
	}
	if len(kept) != len(l.pending) {
		l.dirty = true
	}
	l.pending = kept
}

func slotOf(bucket wire.UsageBucket) slot {
	return slot{MinuteUnix: bucket.Minute.UTC().Unix(), SessionID: bucket.SessionID,
		AccountID: bucket.AccountID, Model: bucket.Model}
}

// Spool is what survives a restart. Open minutes are carried as open, so a restart
// mid-minute resumes the same bucket rather than starting a second one that would
// replace it.
type Spool struct {
	Open    []wire.UsageBucket `json:"open"`
	Pending []wire.UsageBucket `json:"pending"`
}

// TakeSpool is what to write, or false when nothing has changed since the last write.
func (l *Ledger) TakeSpool() (Spool, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.dirty {
		return Spool{}, false
	}
	l.dirty = false
	spool := Spool{Pending: append([]wire.UsageBucket(nil), l.pending...)}
	for _, bucket := range l.open {
		spool.Open = append(spool.Open, bucket)
	}
	sort.Slice(spool.Open, func(i, j int) bool {
		if !spool.Open[i].Minute.Equal(spool.Open[j].Minute.Time) {
			return spool.Open[i].Minute.Before(spool.Open[j].Minute.Time)
		}
		return spool.Open[i].SessionID < spool.Open[j].SessionID
	})
	return spool, true
}

func (l *Ledger) Restore(spool Spool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, bucket := range spool.Open {
		l.open[slotOf(bucket)] = bucket
	}
	l.pending = append(l.pending, spool.Pending...)
	if len(l.pending) > MaxPending {
		l.pending = append([]wire.UsageBucket(nil), l.pending[len(l.pending)-MaxPending:]...)
	}
}

func (l *Ledger) Pending() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.pending)
}

func LoadSpool(path string) (Spool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Spool{}, nil
		}
		return Spool{}, err
	}
	var spool Spool
	return spool, json.Unmarshal(data, &spool)
}
