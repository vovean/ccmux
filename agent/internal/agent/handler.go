package agent

import (
	"context"
	"errors"
	"time"

	"ccmuxagent/internal/control"
)

// Handle answers one control request. The agent is the control socket's Handler.
func (a *Agent) Handle(ctx context.Context, request control.Request) control.Response {
	switch request.Op {
	case control.OpPing:
		return control.Response{OK: true}

	case control.OpNewSession:
		started, err := a.NewSession(ctx, Launch{
			Model:     request.Model,
			AccountID: request.AccountID,
			Group:     request.Group,
			Directory: request.Directory,
			Name:      request.Name,
			PID:       request.PID,
		})
		if err != nil {
			response := control.Response{Error: err.Error()}
			var refusal *ErrNoAccount
			if errors.As(err, &refusal) {
				// Not a fault: an application driving this can wait rather than fail.
				response.Unavailable = true
				if !refusal.At.IsZero() {
					response.RetryAfter = refusal.At.UTC().Format(time.RFC3339)
				}
			}
			return response
		}
		return control.Response{OK: true, Session: &control.SessionInfo{
			SessionID:    started.SessionID,
			NamespaceDir: started.NamespaceDir,
			Port:         started.Port,
			AccountID:    started.AccountID,
			AccountLabel: started.AccountLabel,
			Model:        started.Model,
			Warning:      started.Warning,
			Group:        started.Group,
		}}

	case control.OpEndSession:
		if err := a.EndSession(request.SessionID); err != nil {
			return control.Response{Error: err.Error()}
		}
		return control.Response{OK: true}

	case control.OpAssign:
		if err := a.Assign(ctx, request.SessionID, request.AccountID, Explicit); err != nil {
			return control.Response{Error: err.Error()}
		}
		return control.Response{OK: true}

	case control.OpStatus:
		return control.Response{OK: true, Status: a.Status()}

	default:
		return control.Response{Error: "unknown request " + request.Op}
	}
}
