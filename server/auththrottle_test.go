package main

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"
)

func TestGuessingIsBlockedAfterAHandfulOfFailures(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()

	// A mistyped password a few times over must not lock anyone out.
	for i := 0; i < authFreeAttempts; i++ {
		if wait := throttle.Failed("203.0.113.9", now); wait != 0 {
			t.Fatalf("attempt %d already blocked for %s", i+1, wait)
		}
		if blocked, _ := throttle.Blocked("203.0.113.9", now); blocked {
			t.Fatalf("blocked after %d attempts", i+1)
		}
	}

	wait := throttle.Failed("203.0.113.9", now)
	if wait <= 0 {
		t.Fatal("the attempt past the allowance should have started a block")
	}
	blocked, remaining := throttle.Blocked("203.0.113.9", now)
	if !blocked || remaining <= 0 {
		t.Fatalf("expected a block, got %v %s", blocked, remaining)
	}
}

// Otherwise one guesser would lock out every other machine in the fleet.
func TestOneHostsFailuresDoNotBlockAnother(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < authFreeAttempts+3; i++ {
		throttle.Failed("203.0.113.9", now)
	}
	if blocked, _ := throttle.Blocked("198.51.100.4", now); blocked {
		t.Fatal("an unrelated host was blocked")
	}
}

func TestABlockExpires(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < authFreeAttempts+1; i++ {
		throttle.Failed("203.0.113.9", now)
	}
	if blocked, _ := throttle.Blocked("203.0.113.9", now); !blocked {
		t.Fatal("expected a block")
	}
	if blocked, _ := throttle.Blocked("203.0.113.9", now.Add(authMaxBlock+time.Minute)); blocked {
		t.Fatal("the block should have expired")
	}
}

// The Mac that finally gets it right must not stay penalised for the typos before it.
func TestSuccessClearsTheRecord(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < authFreeAttempts; i++ {
		throttle.Failed("203.0.113.9", now)
	}
	throttle.Succeeded("203.0.113.9", now)
	for i := 0; i < authFreeAttempts; i++ {
		if wait := throttle.Failed("203.0.113.9", now); wait != 0 {
			t.Fatalf("the allowance did not reset: blocked after %d", i+1)
		}
	}
}

func TestTheBlockGrowsButIsCapped(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	var last time.Duration
	for i := 0; i < 40; i++ {
		wait := throttle.Failed("203.0.113.9", now)
		if wait > authMaxBlock {
			t.Fatalf("block ran past the cap: %s", wait)
		}
		if wait > 0 && wait < last {
			t.Fatalf("block shrank from %s to %s", last, wait)
		}
		last = wait
	}
	// Far enough in that the shift would have overflowed a signed duration.
	if last != authMaxBlock {
		t.Fatalf("expected the cap, got %s", last)
	}
}

// The map is keyed by whoever connects, so a scan must not be able to grow it forever.
func TestTheHostTableIsBounded(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < maxAuthHosts+200; i++ {
		throttle.Failed(fmt.Sprintf("198.51.100.%d", i), now)
	}
	throttle.mu.Lock()
	size := len(throttle.byHost)
	throttle.mu.Unlock()
	if size > maxAuthHosts {
		t.Fatalf("table grew to %d", size)
	}
}

func TestThrottleIsRaceFree(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(3)
		host := fmt.Sprintf("203.0.113.%d", i%4)
		go func() { defer wg.Done(); throttle.Failed(host, now) }()
		go func() { defer wg.Done(); _, _ = throttle.Blocked(host, now) }()
		go func() { defer wg.Done(); throttle.Succeeded(host, now) }()
	}
	wg.Wait()
}

// X-Forwarded-For is attacker-controlled here — trusting it would let one source look
// like thousands, which is worse than having no throttle.
func TestTheSourceIsThePeerNotAHeader(t *testing.T) {
	req, _ := http.NewRequest("GET", "https://ccmuxd/v1/health", nil)
	req.RemoteAddr = "203.0.113.9:51234"
	req.Header.Set("X-Forwarded-For", "198.51.100.1")
	if host := requestHost(req); host != "203.0.113.9" {
		t.Fatalf("got %q", host)
	}
}

// End to end: the guard must stop comparing once a source is blocked, and say so.
func TestRepeatedBadPasswordsGetRefusedWithRetryAfter(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	wrong := "Basic " + base64.StdEncoding.EncodeToString([]byte("ccmux:nope"))
	var last int
	for i := 0; i < authFreeAttempts+2; i++ {
		req, _ := http.NewRequest("GET", server.URL+"/v1/health", nil)
		req.Header.Set("Authorization", wrong)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		last = resp.StatusCode
		if last == http.StatusTooManyRequests && resp.Header.Get("Retry-After") == "" {
			t.Fatal("a 429 must say how long to wait")
		}
		resp.Body.Close()
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("expected 429 once the allowance ran out, got %d", last)
	}

	// The security property, and the reason the block is checked before the compare: a
	// blocked source is refused even when it finally presents the right password. Letting
	// a correct one through would mean every guess still gets evaluated, and the throttle
	// would buy nothing but latency.
	blocked := authed(t, client, "GET", server.URL+"/v1/health", "")
	defer blocked.Body.Close()
	if blocked.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("a blocked source got through with %d", blocked.StatusCode)
	}
}

// And the throttle must not be breaking ordinary authentication.
func TestAGoodCredentialIsUnaffected(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	for i := 0; i < authFreeAttempts+5; i++ {
		resp := authed(t, client, "GET", server.URL+"/v1/health", "")
		code := resp.StatusCode
		resp.Body.Close()
		if code != http.StatusOK {
			t.Fatalf("request %d answered %d", i+1, code)
		}
	}
}
