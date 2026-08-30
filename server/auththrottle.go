package main

import (
	"context"
	"net"
	"net/http"
	"sync"
	"time"
)

// Slows password guessing from any one source.
//
// The credential is a single shared password guarding an endpoint that hands out live
// access tokens for every account this server holds, and on a public address there is
// nothing else in front of it. Unlimited silent guesses is not a property worth having
// there, whatever the entropy of the password.
//
// It slows a guesser by holding the answer rather than by refusing the source outright.
// Refusing outright is stronger against one guesser and useless in this deployment: every
// Mac reaches this server through the same VPN egress, so a single stale password would
// have locked out the whole fleet, and a blocked source could never clear itself because
// the correct password was refused too. Holding a wrong answer costs the guesser the one
// thing they need — attempts per second — while a correct password is never delayed at
// all.
type authThrottle struct {
	mu     sync.Mutex
	byHost map[string]*authFailures
	// Bounds how many wrong answers are being held at once, so parallel guessing cannot
	// park an unbounded number of goroutines here. Over the bound, wrong answers are
	// simply returned at once: the guesser gains no more than the parallelism they
	// already had, and this server keeps its memory.
	slots chan struct{}
}

type authFailures struct {
	count    int
	lastSeen time.Time
}

const (
	// Room for a mistyped password without anyone noticing, and no more.
	authFreeAttempts = 5
	authBaseDelay    = 2 * time.Second
	// Capped low on purpose. Against a 24-character random password even one second an
	// attempt is astronomically more time than anyone has; a longer cap would only punish
	// the Mac that shares an egress with whoever fat-fingered it.
	authMaxDelay = 5 * time.Second
	// Entries are dropped once a host has been quiet this long, so a passing scan does
	// not leave anything behind.
	authForget = time.Hour
	// A ceiling, because the map is keyed by whatever address connects to us.
	maxAuthHosts   = 4096
	maxHeldAnswers = 64
)

func newAuthThrottle() *authThrottle {
	return &authThrottle{
		byHost: map[string]*authFailures{},
		slots:  make(chan struct{}, maxHeldAnswers),
	}
}

// Failed records a wrong guess and reports how long its answer should be held.
func (t *authThrottle) Failed(host string, now time.Time) time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pruneLocked(now)
	entry, ok := t.byHost[host]
	if !ok {
		if len(t.byHost) >= maxAuthHosts {
			t.evictStalestLocked()
		}
		entry = &authFailures{}
		t.byHost[host] = entry
	}
	entry.count++
	entry.lastSeen = now
	if entry.count <= authFreeAttempts {
		return 0
	}
	// Doubling, so a persistent guesser spends most of its time waiting.
	wait := authBaseDelay << (entry.count - authFreeAttempts - 1)
	if wait > authMaxDelay || wait <= 0 {
		wait = authMaxDelay
	}
	return wait
}

func (t *authThrottle) Succeeded(host string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.byHost, host)
	t.pruneLocked(now)
}

// Hold waits out a wrong answer's delay. Reports false if the caller went away first,
// which means there is nobody left to answer.
func (t *authThrottle) Hold(ctx context.Context, wait time.Duration) bool {
	if wait <= 0 {
		return true
	}
	select {
	case t.slots <- struct{}{}:
		defer func() { <-t.slots }()
	default:
		return true
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func (t *authThrottle) pruneLocked(now time.Time) {
	for host, entry := range t.byHost {
		if now.Sub(entry.lastSeen) > authForget {
			delete(t.byHost, host)
		}
	}
}

func (t *authThrottle) evictStalestLocked() {
	oldest, at := "", time.Time{}
	for host, entry := range t.byHost {
		if oldest == "" || entry.lastSeen.Before(at) {
			oldest, at = host, entry.lastSeen
		}
	}
	delete(t.byHost, oldest)
}

// requestHost is the peer address and nothing else.
//
// Deliberately not X-Forwarded-For: ccmuxd is spoken to directly, so a header would be
// attacker-controlled and would let one source masquerade as thousands, which is worse
// than no throttle at all.
func requestHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
