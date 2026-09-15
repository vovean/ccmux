// Package proxy is the loopback endpoint one session's Claude Code talks to.
//
// Every request passes through here, and two things happen on the way:
//
//  1. The credential is replaced with the one belonging to whichever account the session
//     is assigned to *right now*. That is what makes mid-flight switching possible —
//     Claude Code resolves its own credential once at startup and never re-reads it.
//  2. A refusal for hitting a limit is retried on another account before Claude Code
//     ever sees it, and the anthropic-ratelimit-unified-* response headers are reported
//     back, which gives exact live usage for free without spending the usage endpoint's
//     hourly budget.
//
// One port per session rather than one shared port with a path prefix: session identity
// is then the port, nothing has to rewrite paths on the way out, and the base URL stays
// in the plain scheme://host:port form Claude Code expects.
package proxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"ccmuxagent/internal/rules"
)

// How a request authenticates. The two schemes are mutually exclusive on the wire, so
// the proxy has to know which one it is holding rather than just "a credential".
type Credential struct {
	// Exactly one of these is set.
	OAuthToken string
	APIKey     string
}

func OAuth(token string) Credential { return Credential{OAuthToken: token} }
func Key(key string) Credential     { return Credential{APIKey: key} }

type Assignment struct {
	AccountID  string
	Credential Credential
}

// Router is what the proxy needs to know to keep a session running across accounts.
// Deliberately narrow: the proxy does not know what an account or a limit window is, it
// asks only who should serve this and who could serve it later.
type Router interface {
	// Assignment is the account and credential to use for the next request.
	Assignment(sessionID string) (Assignment, bool)

	// Failover is where to retry a request the account in `servedBy` refused, or false
	// to give up and let the refusal through. Reassigning the session is the callee's
	// business.
	//
	// `servedBy` matters: the account may have changed while the request was in flight,
	// and a refusal from the old one must not drag the session somewhere it was not sent.
	Failover(sessionID, model, servedBy string, tried map[string]bool) (Assignment, bool)

	// SoonestAvailability is the earliest this session could be served this model, used
	// to tell Claude Code when it is worth trying again. Session-scoped on purpose: a
	// session that may not move can only ever be served by its own account, and naming
	// an earlier moment belonging to another just sends Claude Code back into the same
	// refusal.
	SoonestAvailability(sessionID, model string) (time.Time, bool)
}

// Observation is one attempt's news about the account that served it, reported as soon
// as the headers arrive — a refusal included, which is still real news about that
// account's windows.
type Observation struct {
	SessionID  string
	AccountID  string
	Model      string
	StatusCode int
	// Lower-cased anthropic-ratelimit-* headers only.
	Headers map[string]string
}

// Billing is what one relayed response cost. Reported once the body has finished, and
// never for an attempt that was abandoned for a retry elsewhere.
type Billing struct {
	SessionID string
	AccountID string
	Model     string
	Usage     TokenUsage
	// A line was too big to inspect, so the counts are incomplete and should be
	// recorded as unknown rather than as a confident zero.
	Incomplete bool
}

type Options struct {
	SessionID string
	Upstream  *url.URL
	Router    Router
	Observe   func(Observation)
	Bill      func(Billing)
	Log       func(format string, args ...any)
}

type Proxy struct {
	options  Options
	client   *http.Client
	listener net.Listener
	server   *http.Server
	port     int
}

const (
	// Above this a request is forwarded without being held, which costs it the retry: a
	// body this large is a conversation near the context limit, and buffering several of
	// them at once on a box with a 256 MB memory cap is the worse failure. A measured
	// Claude Code request is about 80 KB.
	maxRetryBody = 8 << 20
	relayChunk   = 32 << 10
)

// Start binds the first free port in [first, last] and serves until Close.
//
// The band is deliberately outside the ephemeral range: the port is baked into the
// session's ANTHROPIC_BASE_URL, so it has to be rebindable after a restart rather than
// being one the kernel may have handed to some other process in the meantime.
func Start(options Options, first, last int) (*Proxy, error) {
	if options.Log == nil {
		options.Log = func(string, ...any) {}
	}
	listener, port, err := listenInBand(first, last)
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = 4
	proxy := &Proxy{
		options:  options,
		listener: listener,
		port:     port,
		// No overall timeout: a streamed answer legitimately runs for minutes, and the
		// request context already ends it when Claude Code goes away.
		client: &http.Client{Transport: transport},
	}
	proxy.server = &http.Server{Handler: proxy}
	go func() {
		if err := proxy.server.Serve(listener); err != nil &&
			!errors.Is(err, http.ErrServerClosed) {
			options.Log("session %s: proxy stopped: %v", options.SessionID, err)
		}
	}()
	return proxy, nil
}

func (p *Proxy) Port() int { return p.port }

func (p *Proxy) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return p.server.Shutdown(ctx)
}

func listenInBand(first, last int) (net.Listener, int, error) {
	for port := first; port <= last; port++ {
		listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err == nil {
			return listener, port, nil
		}
	}
	return nil, 0, fmt.Errorf("no free port in %d-%d", first, last)
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, streamed, err := readBody(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "ccmux could not read the request body")
		return
	}
	// Only a held body can be replayed on another account.
	retryable := streamed == nil
	// The model decides which weekly window gates this request: a spent Fable week does
	// not stop an Opus call, and vice versa. An oversized body still has its first 8 MB
	// here, and the field sits in the first few hundred bytes.
	model := ModelFromBody(body)
	if !retryable {
		model = ""
	}

	assignment, ok := p.options.Router.Assignment(p.options.SessionID)
	if !ok {
		writeError(w, http.StatusServiceUnavailable,
			"ccmux has no account assigned to this session")
		return
	}

	tried := map[string]bool{}
	for {
		response, err := p.send(r, body, streamed, assignment)
		if err != nil {
			if r.Context().Err() != nil {
				// Claude Code hung up; there is nobody to tell.
				return
			}
			writeError(w, http.StatusBadGateway, "ccmux could not reach the API: "+err.Error())
			return
		}

		rateLimit := rateLimitHeaders(response.Header)
		if p.options.Observe != nil {
			p.options.Observe(Observation{
				SessionID: p.options.SessionID, AccountID: assignment.AccountID,
				Model: model, StatusCode: response.StatusCode, Headers: rateLimit,
			})
		}

		headers := relayableHeaders(response.Header)
		if rules.IsRateLimited(rateLimit, response.StatusCode) {
			tried[assignment.AccountID] = true
			// Each account is tried at most once — cycling would also risk Claude Code's
			// own "stopped after repeated usage-limit hits" guard.
			if retryable {
				next, ok := p.options.Router.Failover(p.options.SessionID, model,
					assignment.AccountID, tried)
				if ok {
					// The replaced attempt is still streaming a refusal nobody will read.
					response.Body.Close()
					p.options.Log("session %s: %s refused %s, retrying on %s",
						p.options.SessionID, assignment.AccountID, modelOrRequest(model),
						next.AccountID)
					assignment = next
					continue
				}
			}
			// Nothing can serve it. Claude Code decides whether to wait from
			// anthropic-ratelimit-unified-reset, and refuses to wait at all when that is
			// more than 24 hours out — so it has to describe the soonest moment *any*
			// account frees up, not just this one's window.
			if at, ok := p.options.Router.SoonestAvailability(p.options.SessionID, model); ok {
				if shortened, changed := rules.ShorteningReset(headers, at, time.Now()); changed {
					headers = shortened
					p.options.Log("session %s: no account can serve %s; Claude Code told "+
						"to retry at %s", p.options.SessionID, modelOrRequest(model),
						at.Format(time.RFC3339))
				}
			}
		}
		p.relay(w, response, headers, assignment, model)
		return
	}
}

func modelOrRequest(model string) string {
	if model == "" {
		return "request"
	}
	return model
}

// readBody holds the request so a refusal can be replayed on another account. A body past
// the cap loses only the retry: the part already read is put back in front of the rest,
// and the whole thing streams through.
func readBody(r *http.Request) ([]byte, io.Reader, error) {
	if r.Body == nil {
		return nil, nil, nil
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxRetryBody+1))
	if err != nil {
		return nil, nil, err
	}
	if len(body) > maxRetryBody {
		return nil, io.MultiReader(bytes.NewReader(body), r.Body), nil
	}
	return body, nil, nil
}

func (p *Proxy) send(r *http.Request, body []byte, streamed io.Reader,
	assignment Assignment) (*http.Response, error) {
	target := *p.options.Upstream
	target.Path = strings.TrimSuffix(target.Path, "/") + r.URL.Path
	target.RawQuery = r.URL.RawQuery

	// Exactly one of the two: a held body can be replayed, a streamed one goes once.
	var reader io.Reader
	if streamed != nil {
		reader = streamed
	} else if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), reader)
	if err != nil {
		return nil, err
	}
	for name, values := range r.Header {
		if strippedRequestHeaders[strings.ToLower(name)] {
			continue
		}
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	// The two schemes are mutually exclusive, so whichever is not in use has to be
	// cleared rather than merely left unset — Claude Code sends x-api-key too when
	// ANTHROPIC_API_KEY is exported in the shell, and that would bill another account.
	if assignment.Credential.APIKey != "" {
		request.Header.Set("x-api-key", assignment.Credential.APIKey)
	} else {
		request.Header.Set("Authorization", "Bearer "+assignment.Credential.OAuthToken)
	}
	return p.client.Do(request)
}

// Request headers that describe our hop with Claude Code rather than the upstream call.
// Accept-Encoding is dropped so the transport picks its own and hands back a decoded
// body, which is what lets the usage tap read it and the response be re-framed.
var strippedRequestHeaders = map[string]bool{
	"host": true, "connection": true, "keep-alive": true, "proxy-authenticate": true,
	"proxy-authorization": true, "te": true, "trailer": true, "transfer-encoding": true,
	"upgrade": true, "content-length": true, "accept-encoding": true,
	"authorization": true, "x-api-key": true,
}

var strippedResponseHeaders = map[string]bool{
	"connection": true, "keep-alive": true, "proxy-authenticate": true,
	"proxy-authorization": true, "te": true, "trailer": true, "transfer-encoding": true,
	"upgrade": true,
}

func rateLimitHeaders(header http.Header) map[string]string {
	out := map[string]string{}
	for name, values := range header {
		// Every rate-limit family, not just the unified ones: an API key reports
		// per-minute ceilings under different names entirely.
		folded := strings.ToLower(name)
		if strings.HasPrefix(folded, "anthropic-ratelimit-") && len(values) > 0 {
			out[folded] = values[0]
		}
	}
	return out
}

func relayableHeaders(header http.Header) []rules.Header {
	var out []rules.Header
	for name, values := range header {
		if strippedResponseHeaders[strings.ToLower(name)] {
			continue
		}
		for _, value := range values {
			out = append(out, rules.Header{Name: name, Value: value})
		}
	}
	return out
}

func (p *Proxy) relay(w http.ResponseWriter, response *http.Response, headers []rules.Header,
	assignment Assignment, model string) {
	defer response.Body.Close()
	for _, header := range headers {
		w.Header().Add(header.Name, header.Value)
	}
	w.WriteHeader(response.StatusCode)
	flusher, _ := w.(http.Flusher)

	tap := &UsageTap{}
	buffer := make([]byte, relayChunk)
	for {
		n, err := response.Body.Read(buffer)
		if n > 0 {
			tap.Consume(buffer[:n])
			if _, writeErr := w.Write(buffer[:n]); writeErr != nil {
				break
			}
			// Without this an SSE stream arrives in one lump at the end, and Claude Code
			// shows nothing until the answer is complete.
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			break
		}
	}
	tap.Finish()
	if p.options.Bill != nil {
		p.options.Bill(Billing{
			SessionID: p.options.SessionID, AccountID: assignment.AccountID, Model: model,
			Usage: tap.Current(), Incomplete: tap.DroppedOversizedLine,
		})
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"type": "error",
		// The shape Claude Code expects from the API, so the message reaches the user
		// instead of a parse failure.
		"error": map[string]string{"type": "api_error", "message": message},
	})
}

// ModelFromBody reads the model a /v1/messages request names.
func ModelFromBody(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	if len(body) < 4<<20 {
		var envelope struct {
			Model string `json:"model"`
		}
		if json.Unmarshal(body, &envelope) == nil && envelope.Model != "" {
			return envelope.Model
		}
	}
	// Parsing a multi-megabyte conversation just to read one field is not worth it, and
	// losing the model would silently drop model-scoped eligibility. The field sits in
	// the first few hundred bytes of every Claude Code request.
	return modelFromPrefix(body, 8<<10)
}

func modelFromPrefix(body []byte, limit int) string {
	if len(body) > limit {
		body = body[:limit]
	}
	key := bytes.Index(body, []byte(`"model"`))
	if key < 0 {
		return ""
	}
	rest := body[key+len(`"model"`):]
	colon := bytes.IndexByte(rest, ':')
	if colon < 0 {
		return ""
	}
	rest = rest[colon+1:]
	open := bytes.IndexByte(rest, '"')
	if open < 0 {
		return ""
	}
	rest = rest[open+1:]
	close := bytes.IndexByte(rest, '"')
	if close < 0 {
		return ""
	}
	return string(rest[:close])
}
