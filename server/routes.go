package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The HTTP surface. Every route sits behind basic auth; the paths and the JSON shapes are
// the contract in wire.go.
func NewMux(registry *Registry, machines *MachineStore,
	credential BasicAuthCredential) *http.ServeMux {
	mux := http.NewServeMux()
	throttle := newAuthThrottle()
	guard := func(handler http.HandlerFunc) http.Handler {
		return requireAuth(credential, throttle, handler)
	}

	mux.Handle("GET "+apiPrefix+"/health", guard(func(w http.ResponseWriter, r *http.Request) {
		health := registry.Health()
		health.Machines = machines.Count(time.Now())
		writeJSON(w, http.StatusOK, health)
	}))

	mux.Handle("GET "+apiPrefix+"/accounts", guard(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, AccountListResponse{
			APIVersion: apiVersion,
			Accounts:   registry.List(),
		})
	}))

	mux.Handle("GET "+apiPrefix+"/accounts/{id}/token",
		guard(func(w http.ResponseWriter, r *http.Request) {
			id := r.PathValue("id")
			grant, ok := registry.Token(r.Context(), id)
			if !ok {
				writeError(w, http.StatusNotFound, "no usable credential for "+id)
				return
			}
			writeJSON(w, http.StatusOK, grant)
		}))

	mux.Handle("GET "+apiPrefix+"/accounts/{id}/usage",
		guard(func(w http.ResponseWriter, r *http.Request) {
			id := r.PathValue("id")
			usage, ok := registry.Usage(id)
			if !ok {
				writeError(w, http.StatusNotFound, "no usage recorded for "+id)
				return
			}
			writeJSON(w, http.StatusOK, usage)
		}))

	mux.Handle("POST "+apiPrefix+"/login/start",
		guard(func(w http.ResponseWriter, r *http.Request) {
			var body LoginStartRequest
			if !decodeBody(w, r, &body) {
				return
			}
			started, err := registry.StartLogin(body)
			if err != nil {
				writeError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, started)
		}))

	mux.Handle("POST "+apiPrefix+"/login/finish",
		guard(func(w http.ResponseWriter, r *http.Request) {
			var body LoginFinishRequest
			if !decodeBody(w, r, &body) {
				return
			}
			account, err := registry.FinishLogin(r.Context(), body)
			if err != nil {
				writeError(w, http.StatusBadRequest, RejectionMessage(err))
				return
			}
			writeJSON(w, http.StatusOK, account)
		}))

	mux.Handle("POST "+apiPrefix+"/accounts/adopt",
		guard(func(w http.ResponseWriter, r *http.Request) {
			var body AdoptRequest
			if !decodeBody(w, r, &body) {
				return
			}
			account, err := registry.Adopt(r.Context(), body)
			if err != nil {
				writeError(w, http.StatusBadRequest, RejectionMessage(err))
				return
			}
			writeJSON(w, http.StatusOK, account)
		}))

	mux.Handle("DELETE "+apiPrefix+"/accounts/{id}",
		guard(func(w http.ResponseWriter, r *http.Request) {
			if err := registry.Remove(r.PathValue("id")); err != nil {
				status := http.StatusInternalServerError
				if errors.Is(err, ErrRejected) {
					status = http.StatusNotFound
				}
				writeError(w, status, RejectionMessage(err))
				return
			}
			w.WriteHeader(http.StatusNoContent)
		}))

	// The session view. A report is the machine's whole list, so this replaces rather
	// than merges, and the answer is the world — including the reporter, which the client
	// filters out by its own id. One round trip does both halves of the exchange.
	mux.Handle("POST "+apiPrefix+"/machines/{id}/sessions",
		guard(func(w http.ResponseWriter, r *http.Request) {
			id := r.PathValue("id")
			if !ValidMachineID(id) {
				writeError(w, http.StatusBadRequest, "that is not a usable machine id")
				return
			}
			var body MachineReport
			if !decodeBody(w, r, &body) {
				return
			}
			now := time.Now()
			machines.Report(id, body, now)
			writeJSON(w, http.StatusOK, SessionsResponse{
				APIVersion: apiVersion,
				Machines:   machines.Snapshots(now),
			})
		}))

	mux.Handle("GET "+apiPrefix+"/sessions", guard(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, SessionsResponse{
			APIVersion: apiVersion,
			Machines:   machines.Snapshots(time.Now()),
		})
	}))

	mux.Handle("DELETE "+apiPrefix+"/machines/{id}",
		guard(func(w http.ResponseWriter, r *http.Request) {
			id := r.PathValue("id")
			// Checked here too, not only on the way in: the id is echoed back in the
			// error below, which a Mac shows verbatim in a banner.
			if !ValidMachineID(id) {
				writeError(w, http.StatusBadRequest, "that is not a usable machine id")
				return
			}
			if !machines.Forget(id) {
				writeError(w, http.StatusNotFound, "no machine "+id)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		}))

	return mux
}

// BasicAuthCredential is the single shared credential, per the design's basic-auth
// decision. One credential means revoking one Mac rotates it for all of them; that
// tradeoff is recorded in docs/server.md rather than papered over here.
type BasicAuthCredential struct {
	Username     string
	PasswordHash string
}

// Accepts compares in constant time. A timing oracle on a shared password is not
// theoretical when the endpoint is reachable from anywhere.
func (c BasicAuthCredential) Accepts(username, password string) bool {
	sum := sha256.Sum256([]byte(password))
	given := hex.EncodeToString(sum[:])
	userOK := subtle.ConstantTimeCompare([]byte(username), []byte(c.Username))
	passOK := subtle.ConstantTimeCompare([]byte(given), []byte(strings.ToLower(c.PasswordHash)))
	return userOK == 1 && passOK == 1
}

func requireAuth(credential BasicAuthCredential, throttle *authThrottle,
	next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := requestHost(r)
		now := time.Now()
		if blocked, remaining := throttle.Blocked(host, now); blocked {
			// Refused without comparing, so a blocked source cannot even use the timing
			// of the comparison as a signal.
			w.Header().Set("Retry-After",
				strconv.Itoa(int(remaining.Seconds())+1))
			writeError(w, http.StatusTooManyRequests, "too many failed attempts")
			return
		}

		username, password, ok := parseBasicAuth(r.Header.Get("Authorization"))
		if !ok || !credential.Accepts(username, password) {
			wait := throttle.Failed(host, now)
			// Logged with the source: on a public address this is the only record that
			// anyone is trying, and silence is indistinguishable from nobody trying.
			if wait > 0 {
				logWarn("rejected basic auth from %s — blocking for %s", host, wait)
			} else {
				logWarn("rejected basic auth from %s", host)
			}
			// The realm is what makes a browser and `curl -u` offer a prompt rather than
			// just failing, which matters because this is also how you check the server
			// by hand.
			w.Header().Set("WWW-Authenticate", `Basic realm="ccmuxd", charset="UTF-8"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		throttle.Succeeded(host, now)
		next(w, r)
	})
}

func parseBasicAuth(header string) (string, string, bool) {
	parts := strings.SplitN(header, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Basic") {
		return "", "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		return "", "", false
	}
	// Split on the first colon only: a password may legitimately contain one.
	text := string(decoded)
	idx := strings.Index(text, ":")
	if idx < 0 {
		return "", "", false
	}
	return text[:idx], text[idx+1:], true
}

func decodeBody(w http.ResponseWriter, r *http.Request, into any) bool {
	// Capped: an unauthenticated caller cannot reach here, but a wedged client should not
	// be able to feed the process an unbounded body either.
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	if err := decoder.Decode(into); err != nil {
		writeError(w, http.StatusBadRequest, "could not decode request: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		logWarn("could not write response: %v", err)
	}
}

// The nested envelope is what the client parses; a flat {"error":"..."} decodes to
// nothing and the user is shown raw JSON instead of the message.
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, ServerErrorResponse{Error: ServerErrorDetail{Message: message}})
}
