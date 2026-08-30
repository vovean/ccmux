package main

import (
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
type authThrottle struct {
	mu     sync.Mutex
	byHost map[string]*authFailures
}

type authFailures struct {
	count        int
	blockedUntil time.Time
	lastSeen     time.Time
}

const (
	// Room for a mistyped password without anyone noticing, and no more.
	authFreeAttempts = 5
	authBaseBlock    = 2 * time.Second
	authMaxBlock     = 15 * time.Minute
	// Entries are dropped once a host has been quiet this long, so a passing scan does
	// not leave anything behind.
	authForget = time.Hour
	// A ceiling, because the map is keyed by whatever address connects to us.
	maxAuthHosts = 4096
)

func newAuthThrottle() *authThrottle {
	return &authThrottle{byHost: map[string]*authFailures{}}
}

// Blocked reports whether this host must be refused without even comparing, and for how
// much longer.
func (t *authThrottle) Blocked(host string, now time.Time) (bool, time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	entry, ok := t.byHost[host]
	if !ok || !now.Before(entry.blockedUntil) {
		return false, 0
	}
	return true, entry.blockedUntil.Sub(now)
}

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
	wait := authBaseBlock << (entry.count - authFreeAttempts - 1)
	if wait > authMaxBlock || wait <= 0 {
		wait = authMaxBlock
	}
	entry.blockedUntil = now.Add(wait)
	return wait
}

func (t *authThrottle) Succeeded(host string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.byHost, host)
	t.pruneLocked(now)
}

func (t *authThrottle) pruneLocked(now time.Time) {
	for host, entry := range t.byHost {
		if now.Sub(entry.lastSeen) > authForget && !now.Before(entry.blockedUntil) {
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
