package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"
)

func TestGuessingIsHeldAfterAHandfulOfFailures(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()

	// A mistyped password a few times over must not cost anyone anything.
	for i := 0; i < authFreeAttempts; i++ {
		if wait := throttle.Failed("203.0.113.9", now); wait != 0 {
			t.Fatalf("attempt %d already held for %s", i+1, wait)
		}
	}
	if wait := throttle.Failed("203.0.113.9", now); wait <= 0 {
		t.Fatal("the attempt past the allowance should have been held")
	}
}

// Otherwise one guesser would slow every other machine in the fleet.
func TestOneHostsFailuresDoNotDelayAnother(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < authFreeAttempts+3; i++ {
		throttle.Failed("203.0.113.9", now)
	}
	if wait := throttle.Failed("198.51.100.4", now); wait != 0 {
		t.Fatalf("an unrelated host was held for %s", wait)
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
			t.Fatalf("the allowance did not reset: held after %d", i+1)
		}
	}
}

func TestAQuietHostIsForgotten(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	for i := 0; i < authFreeAttempts+3; i++ {
		throttle.Failed("203.0.113.9", now)
	}
	if wait := throttle.Failed("203.0.113.9", now.Add(authForget+time.Minute)); wait != 0 {
		t.Fatalf("a host quiet for an hour is still held for %s", wait)
	}
}

func TestTheDelayGrowsButIsCapped(t *testing.T) {
	throttle := newAuthThrottle()
	now := time.Now()
	var last time.Duration
	for i := 0; i < 40; i++ {
		wait := throttle.Failed("203.0.113.9", now)
		if wait > authMaxDelay {
			t.Fatalf("delay ran past the cap: %s", wait)
		}
		if wait > 0 && wait < last {
			t.Fatalf("delay shrank from %s to %s", last, wait)
		}
		last = wait
	}
	// Far enough in that the shift would have overflowed a signed duration.
	if last != authMaxDelay {
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

// A client that hangs up mid-hold leaves nobody to answer, and the goroutine must not go
// on sleeping on its behalf.
func TestHoldStopsWhenTheCallerGoesAway(t *testing.T) {
	throttle := newAuthThrottle()
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(20 * time.Millisecond); cancel() }()
	started := time.Now()
	if throttle.Hold(ctx, time.Minute) {
		t.Fatal("Hold claimed it waited out a cancelled request")
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("Hold kept sleeping for %s after the cancel", elapsed)
	}
}

// Parallel guessing must not be able to park an unbounded number of goroutines here.
func TestHeldAnswersAreBounded(t *testing.T) {
	throttle := newAuthThrottle()
	for i := 0; i < maxHeldAnswers; i++ {
		throttle.slots <- struct{}{}
	}
	started := time.Now()
	if !throttle.Hold(context.Background(), time.Minute) {
		t.Fatal("Hold reported a cancelled caller")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Hold waited %s with every slot taken", elapsed)
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
		go func() { defer wg.Done(); throttle.Hold(context.Background(), 0) }()
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

// The bug that locked out the fleet. Every Mac reaches this server from one VPN egress,
// so an address that can be blocked is an address that takes everyone down with it — and
// a correct password could never clear the block, because it was refused before it was
// compared.
func TestACorrectPasswordIsServedDespiteGuessingFromTheSameSource(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	wrong := "Basic " + base64.StdEncoding.EncodeToString([]byte("ccmux:nope"))
	for i := 0; i < authFreeAttempts; i++ {
		req, _ := http.NewRequest("GET", server.URL+"/v1/health", nil)
		req.Header.Set("Authorization", wrong)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}

	resp := authed(t, client, "GET", server.URL+"/v1/health", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("the right password answered %d from a source that had been guessing",
			resp.StatusCode)
	}
}

// The other half of the same bug: trust-on-first-use probes this server with no
// credential at all, by design, once per click of Connect. Counting those as guesses
// spent the whole fleet's allowance before anyone had typed a password.
func TestAnUnauthenticatedProbeIsNotAGuess(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	for i := 0; i < authFreeAttempts*3; i++ {
		req, _ := http.NewRequest("GET", server.URL+"/v1/health", nil)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("probe %d answered %d", i+1, resp.StatusCode)
		}
		resp.Body.Close()
	}

	started := time.Now()
	resp := authed(t, client, "GET", server.URL+"/v1/health", "")
	elapsed := time.Since(started)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("connecting after %d probes answered %d", authFreeAttempts*3,
			resp.StatusCode)
	}
	if elapsed > time.Second {
		t.Fatalf("connecting after probes was held for %s", elapsed)
	}
}

// Guessing still has to cost something, or the throttle is decoration.
func TestAWrongPasswordPastTheAllowanceIsHeld(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	wrong := "Basic " + base64.StdEncoding.EncodeToString([]byte("ccmux:nope"))
	attempt := func() time.Duration {
		req, _ := http.NewRequest("GET", server.URL+"/v1/health", nil)
		req.Header.Set("Authorization", wrong)
		started := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("a wrong password answered %d", resp.StatusCode)
		}
		return time.Since(started)
	}
	for i := 0; i < authFreeAttempts; i++ {
		if elapsed := attempt(); elapsed > time.Second {
			t.Fatalf("attempt %d within the allowance was held for %s", i+1, elapsed)
		}
	}
	if elapsed := attempt(); elapsed < authBaseDelay/2 {
		t.Fatalf("the attempt past the allowance came back in %s", elapsed)
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
