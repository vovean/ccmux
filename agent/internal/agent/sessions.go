package agent

import (
	"context"
	"fmt"
	"time"

	"ccmuxagent/internal/ledger"
	"ccmuxagent/internal/proxy"
	"ccmuxagent/internal/rules"
	"ccmuxd/wire"
)

// Launch is what `ccmux run` asks for.
type Launch struct {
	// The model the run will ask for, which decides which weekly windows gate it. Empty
	// means any, and eligibility then rests on the 5-hour and weekly-all windows alone.
	Model string
	// Pins the session to one account instead of ranking. The pool's own ordering is
	// skipped, but an account that cannot serve the model is still refused.
	AccountID string
	Directory string
	Name      string
	PID       int
}

// Started is what the shim needs to launch claude.
type Started struct {
	SessionID    string
	NamespaceDir string
	Port         int
	AccountID    string
	AccountLabel string
	Model        string
	Warning      string
}

// NewSession picks an account, seeds its credential, binds a proxy and records the run.
//
// The preflight refusal is the point of doing it in this order: an application driving
// `claude -p` wants to hear "nothing is free until 14:00" as a refusal it can queue on,
// not as a failed run it has to interpret.
func (a *Agent) NewSession(ctx context.Context, launch Launch) (Started, error) {
	if launch.PID <= 1 || !Alive(launch.PID) {
		return Started{}, fmt.Errorf("no live process to attach the session to")
	}

	a.mu.Lock()
	accounts, usage := a.poolCopy()
	held := len(a.accounts)
	var pinned wire.RemoteAccount
	var pinErr error
	if launch.AccountID != "" {
		pinned, pinErr = a.usableNamedLocked(launch.AccountID)
	}
	a.mu.Unlock()

	var candidates []wire.RemoteAccount
	if launch.AccountID != "" {
		if pinErr != nil {
			return Started{}, pinErr
		}
		candidates = []wire.RemoteAccount{pinned}
		if !rules.CanServe(launch.Model, usage[candidates[0].ID]) {
			at, known := rules.AvailableAt(launch.Model, usage[candidates[0].ID], a.now())
			refusal := &ErrNoAccount{Model: launch.Model}
			if known {
				refusal.At = at
			}
			return Started{}, refusal
		}
	} else {
		if len(accounts) == 0 && held > 0 {
			// Not exit 75: nothing frees up by waiting, only by a config change or restart.
			return Started{}, fmt.Errorf("every account on the server is excluded or " +
				"refused on this box — see `ccmux status`")
		}
		candidates = rules.RankLeastRemaining(launch.Model, accounts, usage, nil)
		if len(candidates) == 0 {
			refusal := &ErrNoAccount{Model: launch.Model}
			if _, at, known := rules.SoonestAvailable(launch.Model, accounts, usage,
				a.now()); known {
				refusal.At = at
			}
			return Started{}, refusal
		}
	}

	// Each in turn, rather than only the best: an account whose lineage has died still
	// ranks, and refusing every launch until someone notices is a worse answer than
	// taking the next one.
	var chosen wire.RemoteAccount
	var grant Grant
	var lastErr error
	for _, candidate := range candidates {
		drawn, err := a.grantFor(ctx, candidate.ID, minGrantLife)
		if err != nil {
			lastErr = err
			a.log("cannot use %s: %v", candidate.DisplayName(), err)
			continue
		}
		chosen, grant = candidate, drawn
		break
	}
	if chosen.ID == "" {
		return Started{}, fmt.Errorf("no account in the pool has a usable credential: %w",
			lastErr)
	}

	record := Session{
		ID:              newID(),
		PID:             launch.PID,
		AccountID:       chosen.ID,
		SeededAccountID: chosen.ID,
		Model:           launch.Model,
		Directory:       launch.Directory,
		Name:            launch.Name,
		StartedAt:       a.now(),
	}
	namespace := a.config.Namespace(record.ID)
	if err := Seed(namespace, grant, a.now()); err != nil {
		return Started{}, fmt.Errorf("could not seed the session's credential: %w", err)
	}

	bound, err := a.startProxy(record)
	if err != nil {
		_ = Clear(namespace)
		return Started{}, err
	}

	a.mu.Lock()
	a.sessions[bound.record.ID] = bound
	sessions := a.recordsLocked()
	a.mu.Unlock()
	if err := a.store.Save(sessions); err != nil {
		a.log("could not write the sessions file: %v", err)
	}

	started := Started{
		SessionID:    bound.record.ID,
		NamespaceDir: namespace,
		Port:         bound.record.Port,
		AccountID:    chosen.ID,
		AccountLabel: chosen.DisplayName(),
		Model:        launch.Model,
	}
	if chosen.Health == wire.HealthNeedsRelogin {
		started.Warning = "this account needs signing in again"
	}
	a.log("session %s started on %s, port %d", bound.record.ID, chosen.DisplayName(),
		bound.record.Port)
	return started, nil
}

func (a *Agent) EndSession(id string) error {
	a.mu.Lock()
	session, ok := a.sessions[id]
	if ok {
		delete(a.sessions, id)
	}
	sessions := a.recordsLocked()
	a.mu.Unlock()
	if !ok {
		return fmt.Errorf("no session %s", id)
	}
	if session.proxy != nil {
		_ = session.proxy.Close()
	}
	if err := Clear(a.config.Namespace(id)); err != nil {
		a.log("%v", err)
	}
	if err := a.store.Save(sessions); err != nil {
		a.log("could not write the sessions file: %v", err)
	}
	a.log("session %s ended", id)
	return nil
}

// Reason distinguishes a move ccmux chose from one the user asked for.
type Reason int

const (
	// Failover and rebalance: keep the session serving, and leave what it *is* alone.
	Rotation Reason = iota
	// The picker or `ccmux assign`: take the identity too.
	Explicit
)

// SameOrganisation is deliberately false for an unknown organisation on either side. An
// API key carries none, and neither does an account whose profile has not been read yet:
// neither can be shown to leave the identity where it was.
func SameOrganisation(left, right *string) bool {
	if left == nil || right == nil || *left == "" || *right == "" {
		return false
	}
	return *left == *right
}

// MayReseed decides whether a move also rewrites the session's seeded credential.
//
// Claude Code reads that credential to decide its organisation, and an organisation
// mandates managed plugins. Crossing the boundary mid-session makes a plugin that never
// loaded at startup suddenly required, which blocks every model switch after it. A move
// the user asked for is taken whole regardless; one ccmux chose is not.
func MayReseed(reason Reason, seededOrg, targetOrg *string) bool {
	if reason == Explicit {
		return true
	}
	return SameOrganisation(seededOrg, targetOrg)
}

// Assign moves a session to another account.
func (a *Agent) Assign(ctx context.Context, sessionID, accountID string, reason Reason) error {
	a.mu.Lock()
	session, ok := a.sessions[sessionID]
	if !ok {
		a.mu.Unlock()
		return fmt.Errorf("no session %s", sessionID)
	}
	// Only a person's request is resolved by name; a rotation names the exact id it picked.
	var target wire.RemoteAccount
	var err error
	if reason == Explicit {
		target, err = a.usableNamedLocked(accountID)
	} else {
		var known bool
		if target, known = a.account(accountID); !known {
			err = fmt.Errorf("no account %q on the server", accountID)
		} else {
			err = a.refuseUnusableLocked(target)
		}
	}
	seeded, seededKnown := a.account(session.record.SeededAccountID)
	a.mu.Unlock()
	if err != nil {
		return err
	}
	accountID = target.ID

	grant, err := a.grantFor(ctx, accountID, minGrantLife)
	if err != nil {
		return fmt.Errorf("could not draw a credential for %s: %w", target.DisplayName(), err)
	}

	var seededOrg *string
	if seededKnown {
		seededOrg = seeded.OrganizationUUID
	}
	reseed := MayReseed(reason, seededOrg, target.OrganizationUUID)

	// Re-checked before writing anything: drawing the credential above released the lock,
	// and a session reaped in that window would have its namespace recreated here — with
	// a live access token and nothing left that would ever remove it.
	a.mu.Lock()
	session, ok = a.sessions[sessionID]
	if !ok {
		a.mu.Unlock()
		return fmt.Errorf("no session %s", sessionID)
	}
	a.mu.Unlock()

	if reseed {
		// Written before the record moves: a namespace holding the old credential with a
		// record naming the new account is the state a restart cannot tell apart from a
		// rotation, and it would re-seed across the boundary on recovery.
		if err := Seed(a.config.Namespace(sessionID), grant, a.now()); err != nil {
			return fmt.Errorf("could not reseed the session: %w", err)
		}
	}

	a.mu.Lock()
	session, ok = a.sessions[sessionID]
	if !ok {
		a.mu.Unlock()
		// It ended while we were seeding; take the credential back off the disk.
		if clearErr := Clear(a.config.Namespace(sessionID)); clearErr != nil {
			a.log("%v", clearErr)
		}
		return fmt.Errorf("no session %s", sessionID)
	}
	session.record.AccountID = accountID
	if reseed {
		session.record.SeededAccountID = accountID
	}
	sessions := a.recordsLocked()
	a.mu.Unlock()
	if err := a.store.Save(sessions); err != nil {
		a.log("could not write the sessions file: %v", err)
	}
	return nil
}

// --- proxy.Router ---

func (a *Agent) Assignment(sessionID string) (proxy.Assignment, bool) {
	a.mu.Lock()
	session, ok := a.sessions[sessionID]
	if !ok {
		a.mu.Unlock()
		return proxy.Assignment{}, false
	}
	accountID := session.record.AccountID
	a.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	grant, err := a.grantFor(ctx, accountID, minGrantLife)
	if err != nil {
		a.log("session %s: no credential for %s: %v", sessionID, accountID, err)
		return proxy.Assignment{}, false
	}
	return assignmentFor(grant), true
}

func (a *Agent) Failover(sessionID, model, servedBy string,
	tried map[string]bool) (proxy.Assignment, bool) {
	a.mu.Lock()
	session, ok := a.sessions[sessionID]
	if !ok || session.record.AccountID != servedBy {
		// The account changed while the request was in flight, so a refusal from the old
		// one must not drag the session somewhere it was not sent.
		a.mu.Unlock()
		return proxy.Assignment{}, false
	}
	accounts, usage := a.poolCopy()
	a.mu.Unlock()

	next, ok := rules.Pick(model, accounts, usage, tried)
	if !ok {
		return proxy.Assignment{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := a.Assign(ctx, sessionID, next.ID, Rotation); err != nil {
		a.log("session %s: could not move to %s: %v", sessionID, next.ID, err)
		return proxy.Assignment{}, false
	}
	grant, err := a.grantFor(ctx, next.ID, minGrantLife)
	if err != nil {
		return proxy.Assignment{}, false
	}
	return assignmentFor(grant), true
}

func (a *Agent) SoonestAvailability(sessionID, model string) (time.Time, bool) {
	a.mu.Lock()
	accounts, usage := a.poolCopy()
	a.mu.Unlock()
	_, at, ok := rules.SoonestAvailable(model, accounts, usage, a.now())
	return at, ok
}

// --- what the proxy reports back ---

func (a *Agent) observe(observation proxy.Observation) {
	windows := rules.WindowsFromHeaders(observation.Headers)
	if len(windows) == 0 {
		return
	}
	at := a.now()
	a.mu.Lock()
	folded := rules.FoldHeaders(windows, a.usage[observation.AccountID], at)
	a.usage[observation.AccountID] = &folded
	if session, ok := a.sessions[observation.SessionID]; ok {
		session.record.LastRequestAt = at
		session.record.Requests++
	}
	a.mu.Unlock()
}

func (a *Agent) bill(billing proxy.Billing) {
	if billing.Usage.Total() == 0 && !billing.Incomplete {
		return
	}
	a.mu.Lock()
	session, ok := a.sessions[billing.SessionID]
	account, known := a.account(billing.AccountID)
	var name string
	if ok {
		name = session.record.Name
	}
	a.mu.Unlock()

	identity := ledger.Identity{
		SessionID:   billing.SessionID,
		SessionName: name,
		AccountID:   billing.AccountID,
		Model:       billing.Model,
	}
	if known {
		identity.AccountLabel = account.DisplayName()
		identity.Kind = account.Kind
		if account.APIKeyFingerprint != nil {
			identity.AccountFingerprint = *account.APIKeyFingerprint
		}
	}
	counted := ledger.TokenUsage{
		Input: billing.Usage.Input, Output: billing.Usage.Output,
		CacheRead: billing.Usage.CacheRead, CacheWrite5m: billing.Usage.CacheWrite5m,
		CacheWrite1h: billing.Usage.CacheWrite1h,
	}
	// A line too big to inspect means the counts are partial, so the bucket carries no
	// cost at all rather than a confident understatement.
	identity.Unpriced = billing.Incomplete
	a.ledger.Record(counted, identity, a.now())
	if billing.Incomplete {
		a.log("session %s: a usage event was too large to read; that minute is unpriced",
			billing.SessionID)
		return
	}

	if cost, priced := ledger.Cost(billing.Model, counted, a.now()); priced && ok {
		a.mu.Lock()
		if session, still := a.sessions[billing.SessionID]; still {
			session.record.SpendUSD += cost
		}
		a.mu.Unlock()
	}
}
