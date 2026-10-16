package proxy

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// Well clear of the 18000-18999 band a real agent uses, so a test never takes a port a
// live session has baked into its ANTHROPIC_BASE_URL.
const testFirst, testLast = 19700, 19799

type stubRouter struct {
	mu        sync.Mutex
	assign    Assignment
	next      *Assignment
	soonest   *time.Time
	failovers []string
	triedSeen []map[string]bool
	refused   []string
	fresh     *Assignment
	freshBy   map[string]Assignment
	redraws   []string
}

func (s *stubRouter) Redraw(accountID string, refused Credential) (Assignment, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.redraws = append(s.redraws, accountID+":"+refused.OAuthToken)
	if fresh, ok := s.freshBy[accountID]; ok {
		return fresh, true
	}
	if s.fresh == nil {
		return Assignment{}, false
	}
	return *s.fresh, true
}

func (s *stubRouter) OrganizationRefused(accountID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refused = append(s.refused, accountID)
}

func (s *stubRouter) Assignment(string) (Assignment, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.assign.AccountID == "" {
		return Assignment{}, false
	}
	return s.assign, true
}

func (s *stubRouter) Failover(_, _, servedBy string, tried map[string]bool) (Assignment, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failovers = append(s.failovers, servedBy)
	copied := map[string]bool{}
	for k, v := range tried {
		copied[k] = v
	}
	s.triedSeen = append(s.triedSeen, copied)
	if s.next == nil {
		return Assignment{}, false
	}
	out := *s.next
	s.next = nil
	return out, true
}

func (s *stubRouter) SoonestAvailability(string, string) (time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.soonest == nil {
		return time.Time{}, false
	}
	return *s.soonest, true
}

type harness struct {
	proxy        *Proxy
	router       *stubRouter
	mu           sync.Mutex
	observations []Observation
	billings     []Billing
}

// The handler bills after the last byte is written, so a client that has finished reading
// may still be ahead of it. Every read waits for the count it expects rather than
// sampling whatever has arrived.
func (h *harness) waitForBillings(t *testing.T, want int) []Billing {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		h.mu.Lock()
		got := append([]Billing(nil), h.billings...)
		h.mu.Unlock()
		if len(got) >= want {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("waited for %d billing(s), saw %d", want, len(got))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (h *harness) waitForObservations(t *testing.T, want int) []Observation {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		h.mu.Lock()
		got := append([]Observation(nil), h.observations...)
		h.mu.Unlock()
		if len(got) >= want {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("waited for %d observation(s), saw %d", want, len(got))
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func start(t *testing.T, router *stubRouter, upstream http.HandlerFunc) *harness {
	t.Helper()
	server := httptest.NewServer(upstream)
	t.Cleanup(server.Close)
	base, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{router: router}
	proxy, err := Start(Options{
		SessionID: "sess-1",
		Upstream:  base,
		Router:    router,
		Observe: func(o Observation) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.observations = append(h.observations, o)
		},
		Bill: func(b Billing) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.billings = append(h.billings, b)
		},
	}, testFirst, testLast)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = proxy.Close() })
	h.proxy = proxy
	return h
}

func (h *harness) post(t *testing.T, target, body string,
	headers map[string]string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost,
		fmt.Sprintf("http://127.0.0.1:%d%s", h.proxy.Port(), target), strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = response.Body.Close() })
	return response
}

const messageBody = `{"model":"claude-fable-5-1","max_tokens":16,"messages":[]}`

// The whole point of the proxy: the refusal arrives here first, so an account that still
// has headroom serves the same request and Claude Code never learns there was a problem.
func TestARefusalIsRetriedOnAnotherAccountUnseen(t *testing.T) {
	var mu sync.Mutex
	var seenBodies []string
	router := &stubRouter{
		assign: Assignment{AccountID: "a", Credential: OAuth("token-a")},
		next:   &Assignment{AccountID: "b", Credential: OAuth("token-b")},
	}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		seenBodies = append(seenBodies, string(body))
		mu.Unlock()
		if r.Header.Get("Authorization") == "Bearer token-a" {
			w.Header().Set("anthropic-ratelimit-unified-status", "rejected")
			w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "1.0")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"type":"error"}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":"served by b"}`))
	})

	response := h.post(t, "/v1/messages?beta=true", messageBody, nil)
	body, _ := io.ReadAll(response.Body)

	if response.StatusCode != http.StatusOK {
		t.Fatalf("Claude Code saw %d, not the retry's answer", response.StatusCode)
	}
	if string(body) != `{"ok":"served by b"}` {
		t.Fatalf("body %q", body)
	}
	mu.Lock()
	bodies := append([]string(nil), seenBodies...)
	mu.Unlock()
	if len(bodies) != 2 || bodies[0] != bodies[1] {
		t.Fatalf("the retry did not replay the same body: %q", bodies)
	}
	router.mu.Lock()
	failovers := append([]string(nil), router.failovers...)
	tried := router.triedSeen[0]
	router.mu.Unlock()
	if len(failovers) != 1 || failovers[0] != "a" {
		t.Fatalf("failover asked about %v", failovers)
	}
	// The account that refused has to be in `tried`, or a cycle is possible.
	if !tried["a"] {
		t.Error("the refusing account was not marked as tried")
	}
	// A refusal is still real news about the account that produced it.
	observations := h.waitForObservations(t, 2)
	if len(observations) != 2 || observations[0].StatusCode != 429 ||
		observations[0].AccountID != "a" || observations[1].AccountID != "b" {
		t.Fatalf("observations %+v", observations)
	}
	// Only the attempt that was actually served costs anything.
	billings := h.waitForBillings(t, 1)
	if len(billings) != 1 || billings[0].AccountID != "b" {
		t.Fatalf("billings %+v", billings)
	}
}

func TestQueryAndPathReachTheUpstreamUnchanged(t *testing.T) {
	var mu sync.Mutex
	var seen string
	router := &stubRouter{assign: Assignment{AccountID: "a", Credential: OAuth("t")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = r.URL.RequestURI()
		mu.Unlock()
		_, _ = w.Write([]byte(`{}`))
	})
	response := h.post(t, "/v1/messages?beta=true", messageBody, nil)
	_, _ = io.ReadAll(response.Body)
	mu.Lock()
	defer mu.Unlock()
	if seen != "/v1/messages?beta=true" {
		t.Fatalf("upstream saw %q", seen)
	}
}

// If ANTHROPIC_API_KEY is exported in the shell Claude Code sends x-api-key too, and
// leaving it in place would bill an account other than the one assigned here.
func TestTheUnusedSchemeIsClearedNotJustLeftUnset(t *testing.T) {
	for _, tc := range []struct {
		name       string
		credential Credential
		wantAuth   string
		wantKey    string
	}{
		{"oauth", OAuth("token-a"), "Bearer token-a", ""},
		{"api key", Key("sk-real"), "", "sk-real"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mu sync.Mutex
			var auth, key string
			router := &stubRouter{assign: Assignment{AccountID: "a", Credential: tc.credential}}
			h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				auth, key = r.Header.Get("Authorization"), r.Header.Get("x-api-key")
				mu.Unlock()
				_, _ = w.Write([]byte(`{}`))
			})
			response := h.post(t, "/v1/messages", messageBody, map[string]string{
				"x-api-key":      "sk-from-the-shell",
				"Authorization":  "Bearer stale-from-claude-code",
				"anthropic-beta": "oauth-2025-04-20",
			})
			_, _ = io.ReadAll(response.Body)
			mu.Lock()
			defer mu.Unlock()
			if auth != tc.wantAuth {
				t.Errorf("Authorization = %q, want %q", auth, tc.wantAuth)
			}
			if key != tc.wantKey {
				t.Errorf("x-api-key = %q, want %q", key, tc.wantKey)
			}
		})
	}
}

func TestHeadersClaudeCodeSetsAreForwarded(t *testing.T) {
	var mu sync.Mutex
	var beta string
	router := &stubRouter{assign: Assignment{AccountID: "a", Credential: OAuth("t")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		beta = r.Header.Get("anthropic-beta")
		mu.Unlock()
		_, _ = w.Write([]byte(`{}`))
	})
	response := h.post(t, "/v1/messages", messageBody,
		map[string]string{"anthropic-beta": "claude-code-20250219,oauth-2025-04-20"})
	_, _ = io.ReadAll(response.Body)
	mu.Lock()
	defer mu.Unlock()
	if beta != "claude-code-20250219,oauth-2025-04-20" {
		t.Fatalf("anthropic-beta = %q", beta)
	}
}

// A streamed answer has to arrive as it is produced, or Claude Code shows nothing until
// the whole response is finished.
func TestAStreamedResponseIsRelayedAsItArrives(t *testing.T) {
	release := make(chan struct{})
	router := &stubRouter{assign: Assignment{AccountID: "a", Credential: OAuth("t")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher := w.(http.Flusher)
		_, _ = w.Write([]byte("event: message_start\ndata: {\"type\":\"message_start\"}\n\n"))
		flusher.Flush()
		<-release
		_, _ = w.Write([]byte("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
		flusher.Flush()
	})

	request, _ := http.NewRequest(http.MethodPost,
		fmt.Sprintf("http://127.0.0.1:%d/v1/messages", h.proxy.Port()),
		strings.NewReader(messageBody))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()

	// The first event must be readable while the upstream is still holding the second.
	buffer := make([]byte, 64)
	n, err := response.Body.Read(buffer)
	if err != nil {
		t.Fatalf("nothing arrived before the upstream finished: %v", err)
	}
	if !strings.Contains(string(buffer[:n]), "message_start") {
		t.Fatalf("first chunk was %q", buffer[:n])
	}
	close(release)
	rest, _ := io.ReadAll(response.Body)
	if !strings.Contains(string(rest), "message_stop") {
		t.Fatalf("rest was %q", rest)
	}
}

func TestTheTokensOfAStreamedAnswerAreCounted(t *testing.T) {
	router := &stubRouter{assign: Assignment{AccountID: "a", Credential: OAuth("t")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, line := range transcript {
			_, _ = w.Write([]byte(line))
		}
	})
	response := h.post(t, "/v1/messages", messageBody, nil)
	_, _ = io.ReadAll(response.Body)

	billings := h.waitForBillings(t, 1)
	if len(billings) != 1 {
		t.Fatalf("billings %+v", billings)
	}
	got := billings[0]
	want := TokenUsage{Input: 7, Output: 214, CacheRead: 12000, CacheWrite5m: 22028}
	if got.Usage != want {
		t.Errorf("usage = %+v, want %+v", got.Usage, want)
	}
	if got.Model != "claude-fable-5-1" {
		t.Errorf("model = %q", got.Model)
	}
	if got.Incomplete {
		t.Error("counts reported as incomplete")
	}
}

// When nothing can serve the request the refusal goes through untouched except for the
// one header that tells Claude Code when to come back.
func TestWithNoAccountLeftOnlyTheResetIsRewritten(t *testing.T) {
	soonest := time.Now().Add(2 * time.Hour).Truncate(time.Second)
	router := &stubRouter{
		assign:  Assignment{AccountID: "a", Credential: OAuth("token-a")},
		soonest: &soonest,
	}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("anthropic-ratelimit-unified-status", "rejected")
		w.Header().Set("anthropic-ratelimit-unified-reset",
			fmt.Sprint(time.Now().Add(48*time.Hour).Unix()))
		w.Header().Set("x-request-id", "req-42")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"type":"error","error":{"message":"rate_limit"}}`))
	})

	response := h.post(t, "/v1/messages", messageBody, nil)
	body, _ := io.ReadAll(response.Body)

	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status %d", response.StatusCode)
	}
	if string(body) != `{"type":"error","error":{"message":"rate_limit"}}` {
		t.Errorf("the refusal body was altered: %q", body)
	}
	if response.Header.Get("x-request-id") != "req-42" {
		t.Error("an unrelated header was lost")
	}
	if got := response.Header.Get("anthropic-ratelimit-unified-reset"); got !=
		fmt.Sprint(soonest.Unix()) {
		t.Errorf("reset = %q, want %d", got, soonest.Unix())
	}
}

func TestWithNoAssignmentTheRequestIsRefusedInTheApiShape(t *testing.T) {
	h := start(t, &stubRouter{}, func(w http.ResponseWriter, r *http.Request) {
		t.Error("the upstream should not have been reached")
	})
	response := h.post(t, "/v1/messages", messageBody, nil)
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status %d", response.StatusCode)
	}
	body, _ := io.ReadAll(response.Body)
	if !strings.Contains(string(body), `"type":"error"`) {
		t.Errorf("Claude Code needs the API's error shape, got %q", body)
	}
}

func TestModelFromBody(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		want string
	}{
		{"a plain request", `{"model":"claude-opus-5","messages":[]}`, "claude-opus-5"},
		{"the field late in the object", `{"messages":[],"model":"claude-fable-5-1"}`, "claude-fable-5-1"},
		{"no model at all", `{"messages":[]}`, ""},
		{"not json", `not json at all`, ""},
		{"empty", ``, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ModelFromBody([]byte(tc.body)); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
	// Past the full-parse threshold the prefix scan is what answers, and Claude Code
	// puts the field in the first few hundred bytes of every request.
	big := `{"model":"claude-opus-5","messages":["` + strings.Repeat("x", 5<<20) + `"]}`
	if got := ModelFromBody([]byte(big)); got != "claude-opus-5" {
		t.Errorf("oversized body: got %q", got)
	}
}

// What the API answers, verbatim, when an organisation has turned subscription access for
// Claude Code off.
const organisationRefusal = `{"type":"error","error":{"type":"permission_error",` +
	`"message":"OAuth authentication is currently not allowed for this organization.",` +
	`"details":{"error_code":"oauth_not_allowed_for_organization"}},"request_id":"req_1"}`

// A refusal with no reset must not stall a run: the account's organisation is reported so
// nothing is sent there again, and the request is served elsewhere unseen.
func TestAnOrganisationRefusalIsServedElsewhereAndReported(t *testing.T) {
	router := &stubRouter{
		assign: Assignment{AccountID: "emcd2", Credential: OAuth("token-emcd2")},
		next:   &Assignment{AccountID: "win", Credential: OAuth("token-win")},
	}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer token-emcd2" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(organisationRefusal))
			return
		}
		_, _ = w.Write([]byte(`{"ok":"served by win"}`))
	})

	response := h.post(t, "/v1/messages", messageBody, nil)
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK || string(body) != `{"ok":"served by win"}` {
		t.Fatalf("Claude Code saw %d %q", response.StatusCode, body)
	}
	router.mu.Lock()
	defer router.mu.Unlock()
	if len(router.refused) != 1 || router.refused[0] != "emcd2" {
		t.Errorf("reported %v", router.refused)
	}
	if len(router.failovers) != 1 || !router.triedSeen[0]["emcd2"] {
		t.Errorf("failover %v tried %v", router.failovers, router.triedSeen)
	}
}

// Reading a 403 to classify it must not cost the body when it is relayed after all.
func TestAForbiddenThatIsNotTheRefusalIsRelayedWhole(t *testing.T) {
	long := `{"type":"error","error":{"type":"permission_error","message":"` +
		strings.Repeat("x", 3*refusalPeek) + `"}}`
	for _, tc := range []struct {
		name       string
		credential Credential
		body       string
		reported   bool
	}{
		{"another permission error", OAuth("token-a"), long, false},
		// An API key is not subject to the policy, so the code cannot mean its account.
		{"the refusal, to an API key", Key("key-a"), organisationRefusal, false},
		// Reported, but with nowhere else to go the refusal still arrives intact.
		{"the refusal, nowhere to go", OAuth("token-a"), organisationRefusal, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			router := &stubRouter{assign: Assignment{AccountID: "a", Credential: tc.credential}}
			h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(tc.body))
			})
			response := h.post(t, "/v1/messages", messageBody, nil)
			body, _ := io.ReadAll(response.Body)
			if response.StatusCode != http.StatusForbidden || string(body) != tc.body {
				t.Fatalf("status %d, body of %d bytes (want %d)", response.StatusCode,
					len(body), len(tc.body))
			}
			router.mu.Lock()
			defer router.mu.Unlock()
			if got := len(router.refused) == 1; got != tc.reported {
				t.Errorf("reported %v", router.refused)
			}
		})
	}
}

// ccmuxd rotates a lineage ten minutes before its token expires, which revokes the token a
// running session was still sending. A fresh draw serves the request instead of ending it.
func TestARevokedTokenIsRedrawnAndTheRequestReplayedOnce(t *testing.T) {
	for _, tc := range []struct {
		name      string
		fresh     *Assignment
		wantCode  int
		wantDraws int
	}{
		{"a fresher token serves it", &Assignment{AccountID: "gmail",
			Credential: OAuth("token-new")}, http.StatusOK, 1},
		{"no fresher token, the 401 goes through", nil, http.StatusUnauthorized, 1},
		{"refused again after the redraw, no second redraw", &Assignment{AccountID: "gmail",
			Credential: OAuth("token-also-revoked")}, http.StatusUnauthorized, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			router := &stubRouter{
				assign: Assignment{AccountID: "gmail", Credential: OAuth("token-old")},
				fresh:  tc.fresh,
			}
			h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer token-new" {
					w.WriteHeader(http.StatusUnauthorized)
					_, _ = w.Write([]byte(`{"type":"error","error":{"type":` +
						`"authentication_error","message":"OAuth token revoked"}}`))
					return
				}
				_, _ = w.Write([]byte(`{"ok":true}`))
			})
			response := h.post(t, "/v1/messages", messageBody, nil)
			_, _ = io.ReadAll(response.Body)
			if response.StatusCode != tc.wantCode {
				t.Fatalf("Claude Code saw %d", response.StatusCode)
			}
			router.mu.Lock()
			defer router.mu.Unlock()
			if len(router.redraws) != tc.wantDraws || router.redraws[0] != "gmail:token-old" {
				t.Errorf("redraws %v", router.redraws)
			}
		})
	}
}

func TestAnAPIKeyRefusedAs401IsNotRedrawn(t *testing.T) {
	router := &stubRouter{assign: Assignment{AccountID: "key", Credential: Key("sk-ant-x")},
		fresh: &Assignment{AccountID: "key", Credential: Key("sk-ant-y")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})
	response := h.post(t, "/v1/messages", messageBody, nil)
	_, _ = io.ReadAll(response.Body)
	router.mu.Lock()
	defer router.mu.Unlock()
	if response.StatusCode != http.StatusUnauthorized || len(router.redraws) != 0 {
		t.Fatalf("status %d, redraws %v", response.StatusCode, router.redraws)
	}
}

// One redraw per account, not per request: a request that fails over to a second account
// holding a stale token gets that one redrawn too.
func TestEachAccountARequestReachesGetsItsOwnRedraw(t *testing.T) {
	router := &stubRouter{
		assign: Assignment{AccountID: "a", Credential: OAuth("a-old")},
		next:   &Assignment{AccountID: "c", Credential: OAuth("c-old")},
		freshBy: map[string]Assignment{
			"a": {AccountID: "a", Credential: OAuth("a-new")},
			"c": {AccountID: "c", Credential: OAuth("c-new")},
		},
	}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		switch r.Header.Get("Authorization") {
		case "Bearer a-new":
			w.Header().Set("anthropic-ratelimit-unified-status", "rejected")
			w.WriteHeader(http.StatusTooManyRequests)
		case "Bearer c-new":
			_, _ = w.Write([]byte(`{"ok":true}`))
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	})
	response := h.post(t, "/v1/messages", messageBody, nil)
	_, _ = io.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("Claude Code saw %d", response.StatusCode)
	}
}

// A body too big to replay cannot be retried, but the next request should not carry the
// refused token too.
func TestARefusedRequestTooBigToReplayStillRedraws(t *testing.T) {
	router := &stubRouter{assign: Assignment{AccountID: "a", Credential: OAuth("a-old")},
		fresh: &Assignment{AccountID: "a", Credential: OAuth("a-new")}}
	h := start(t, router, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusUnauthorized)
	})
	huge := `{"model":"claude-opus-5","pad":"` + strings.Repeat("x", maxRetryBody+1) + `"}`
	response := h.post(t, "/v1/messages", huge, nil)
	_, _ = io.ReadAll(response.Body)
	router.mu.Lock()
	defer router.mu.Unlock()
	if response.StatusCode != http.StatusUnauthorized || len(router.redraws) != 1 {
		t.Fatalf("status %d, redraws %v", response.StatusCode, router.redraws)
	}
}
