// Package control is the local socket an application drives the agent through.
//
// A unix socket in a directory only the agent's own user can enter, not an HTTP port:
// what crosses it decides which subscription a run bills to, and a loopback port is
// reachable by every user on the box.
package control

// Request is one command. Newline-delimited JSON, one request and one response per
// connection, so a wedged client cannot hold a conversation open.
type Request struct {
	Op string `json:"op"`
	// newSession
	Model     string `json:"model,omitempty"`
	AccountID string `json:"accountID,omitempty"`
	Directory string `json:"cwd,omitempty"`
	Name      string `json:"name,omitempty"`
	PID       int    `json:"pid,omitempty"`
	// endSession, assign
	SessionID string `json:"sessionID,omitempty"`
}

const (
	OpPing       = "ping"
	OpNewSession = "newSession"
	OpEndSession = "endSession"
	OpAssign     = "assign"
	OpStatus     = "status"
)

// SessionInfo is what the shim needs to launch claude.
type SessionInfo struct {
	SessionID    string `json:"sessionID"`
	NamespaceDir string `json:"namespaceDir"`
	Port         int    `json:"port"`
	AccountID    string `json:"accountID"`
	AccountLabel string `json:"accountLabel"`
	Model        string `json:"model,omitempty"`
	Warning      string `json:"warning,omitempty"`
}

type Response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	// Set when the refusal is "nothing can serve this yet" rather than a fault, so a
	// caller can wait rather than give up. RFC 3339, absent when nothing is known to
	// free up at all.
	RetryAfter  string       `json:"retryAfter,omitempty"`
	Unavailable bool         `json:"unavailable,omitempty"`
	Session     *SessionInfo `json:"session,omitempty"`
	Status      any          `json:"status,omitempty"`
}
