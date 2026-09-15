// Package agent is the daemon: it owns the sessions on this box, the proxy each one
// talks to, the credential seeded into each one's namespace, and what this box tells
// ccmuxd about itself.
package agent

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"sync"
	"time"

	"ccmuxagent/internal/client"
	"ccmuxagent/internal/config"
	"ccmuxagent/internal/ledger"
	"ccmuxagent/internal/proxy"
	"ccmuxagent/internal/rules"
	"ccmuxd/wire"
)

const (
	// The housekeeping cadence, matching the Mac's: reap, renew, refresh, report.
	Tick = 20 * time.Second
	// A grant is renewed this far before it runs out, so a request never picks up a
	// token that expires while it is in flight.
	renewBefore = 10 * time.Minute
	// Below this the cached grant is not worth handing to a proxy at all.
	minGrantLife = 60 * time.Second
	// How long after its last request a session still counts as working. `claude -p`
	// writes no status of its own, so this is the only signal there is.
	busyFor = 90 * time.Second
)

type live struct {
	record Session
	proxy  *proxy.Proxy
}

type Agent struct {
	config  config.Config
	client  *client.Client
	machine Machine
	store   *Store
	ledger  *ledger.Ledger
	log     func(string, ...any)
	now     func() time.Time

	// Serialises token draws so a burst of first requests does not ask ccmuxd once per
	// goroutine for the same account.
	drawMu sync.Mutex

	mu         sync.Mutex
	sessions   map[string]*live
	accounts   []wire.RemoteAccount
	usage      map[string]*rules.Snapshot
	grants     map[string]Grant
	reportsOK  bool
	seriesOK   bool
	lastReport string
}

func New(cfg config.Config, api *client.Client, log func(string, ...any)) (*Agent, error) {
	machine, err := LoadMachine(cfg.MachineFile(), cfg.Agent.Label)
	if err != nil {
		return nil, err
	}
	return &Agent{
		config:   cfg,
		client:   api,
		machine:  machine,
		store:    NewStore(cfg.SessionsFile()),
		ledger:   ledger.New(),
		log:      log,
		now:      time.Now,
		sessions: map[string]*live{},
		usage:    map[string]*rules.Snapshot{},
		grants:   map[string]Grant{},
	}, nil
}

func (a *Agent) Machine() Machine { return a.machine }

// ErrNoAccount is a launch refused because nothing in the pool can serve the model. The
// caller turns it into an exit code an application can queue on.
type ErrNoAccount struct {
	Model string
	// When some account frees up. Zero when nothing known can ever serve it.
	At time.Time
}

func (e *ErrNoAccount) Error() string {
	what := e.Model
	if what == "" {
		what = "this request"
	}
	if e.At.IsZero() {
		return fmt.Sprintf("no account can serve %s, and none has a known reset", what)
	}
	return fmt.Sprintf("no account can serve %s until %s", what,
		e.At.UTC().Format(time.RFC3339))
}

// Start reads the pool, recovers the sessions that outlived the last run, and returns.
func (a *Agent) Start(ctx context.Context) error {
	health, err := a.client.Health(ctx)
	if err != nil {
		return fmt.Errorf("could not reach ccmuxd: %w", err)
	}
	a.mu.Lock()
	a.reportsOK = client.Supports(health, "sessions")
	a.seriesOK = client.Supports(health, "usage-series")
	a.mu.Unlock()
	if a.config.Reports() && !(a.reportsOK && a.seriesOK) {
		a.log("this ccmuxd does not advertise sessions or usage-series; " +
			"this box will not appear on the fleet pages")
	}

	if spool, err := ledger.LoadSpool(a.config.SpoolFile()); err != nil {
		a.log("could not read the usage spool: %v", err)
	} else {
		a.ledger.Restore(spool)
	}

	if err := a.refresh(ctx); err != nil {
		return err
	}
	a.recover()
	return nil
}

// Run is the housekeeping loop. It returns when the context is cancelled, having written
// the spool so nothing counted is lost.
func (a *Agent) Run(ctx context.Context) {
	ticker := time.NewTicker(Tick)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			a.shutdown()
			return
		case <-ticker.C:
			a.housekeep(ctx)
		}
	}
}

func (a *Agent) housekeep(ctx context.Context) {
	a.reap()
	if err := a.refresh(ctx); err != nil {
		a.log("could not refresh the pool: %v", err)
	}
	a.renewGrants(ctx)
	a.ledger.CloseElapsed(a.now())
	a.report(ctx)
	a.pushUsage(ctx)
	a.saveSpool()
}

func (a *Agent) shutdown() {
	a.mu.Lock()
	for _, session := range a.sessions {
		if session.proxy != nil {
			_ = session.proxy.Close()
		}
	}
	sessions := a.recordsLocked()
	a.mu.Unlock()
	// Deliberately without closing the open minute: the agent is restarted while its
	// sessions keep running, and half a minute sent early would be replaced by the half
	// recorded after the restart rather than added to it.
	if err := a.store.Save(sessions); err != nil {
		a.log("could not write the sessions file: %v", err)
	}
	a.saveSpool()
}

// refresh re-reads the account list and each account's usage from ccmuxd. Reading usage
// costs nothing upstream — ccmuxd answers from its own cache and does the real polling.
func (a *Agent) refresh(ctx context.Context) error {
	accounts, err := a.client.Accounts(ctx)
	if err != nil {
		return err
	}
	observed := a.now()
	type answer struct {
		windows []wire.UsageWindow
		at      time.Time
	}
	answers := make(map[string]answer, len(accounts))
	for _, account := range accounts {
		usage, err := a.client.Usage(ctx, account.ID)
		if err != nil {
			var status *client.StatusError
			// A 404 is an account ccmuxd has no numbers for yet, which is ordinary.
			if !errors.As(err, &status) || status.Status != 404 {
				a.log("could not read usage for %s: %v", account.DisplayName(), err)
			}
			continue
		}
		// The answer is as old as ccmuxd's own cache says, not as old as this moment.
		answers[account.ID] = answer{windows: usage.Windows,
			at: observed.Add(-time.Duration(usage.AgeSeconds * float64(time.Second)))}
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	a.accounts = accounts
	// Folded here rather than beside each request: a response header observed during the
	// loop above lands in a.usage, and folding against a copy taken before it would
	// throw that newer reading away.
	for id, got := range answers {
		folded := rules.FoldEndpoint(got.windows, a.usage[id], got.at)
		a.usage[id] = &folded
	}
	// Forget accounts the server no longer has, so nothing ranks on a stale snapshot.
	known := make(map[string]bool, len(accounts))
	for _, account := range accounts {
		known[account.ID] = true
	}
	for id := range a.usage {
		if !known[id] {
			delete(a.usage, id)
		}
	}
	return nil
}

func (a *Agent) account(id string) (wire.RemoteAccount, bool) {
	for _, candidate := range a.accounts {
		if candidate.ID == id {
			return candidate, true
		}
	}
	return wire.RemoteAccount{}, false
}

// usageCopy is a snapshot of the ranking inputs, taken under the lock so ranking itself
// can run without holding it.
func (a *Agent) usageCopy() (accounts []wire.RemoteAccount, usage map[string]*rules.Snapshot) {
	accounts = append([]wire.RemoteAccount(nil), a.accounts...)
	usage = make(map[string]*rules.Snapshot, len(a.usage))
	for id, snapshot := range a.usage {
		usage[id] = snapshot
	}
	return accounts, usage
}

// grantFor returns a usable credential for the account, drawing one when what is cached
// is too near its end. Never called with the agent's lock held: it talks to ccmuxd.
// `wanted` is how much life the caller needs left on it: a request needs only enough to
// finish, while the renewal tick deliberately asks for far more so the draw happens
// before a run is anywhere near losing its credential.
func (a *Agent) grantFor(ctx context.Context, accountID string, wanted time.Duration) (Grant, error) {
	now := a.now()
	a.mu.Lock()
	grant, cached := a.grants[accountID]
	a.mu.Unlock()
	if cached && grant.usable(now.Add(wanted)) {
		return grant, nil
	}

	a.drawMu.Lock()
	defer a.drawMu.Unlock()
	// Another goroutine may have drawn one while we waited.
	a.mu.Lock()
	grant, cached = a.grants[accountID]
	a.mu.Unlock()
	if cached && grant.usable(a.now().Add(wanted)) {
		return grant, nil
	}

	answer, err := a.client.Token(ctx, accountID)
	if err != nil {
		return Grant{}, err
	}
	drawn := grantFromWire(answer, a.now())
	if !drawn.usable(a.now()) {
		return Grant{}, fmt.Errorf("ccmuxd returned no usable credential for %s", accountID)
	}
	a.mu.Lock()
	a.grants[accountID] = drawn
	a.mu.Unlock()
	return drawn, nil
}

func assignmentFor(grant Grant) proxy.Assignment {
	if grant.Kind == wire.KindAPIKey {
		return proxy.Assignment{AccountID: grant.AccountID, Credential: proxy.Key(grant.APIKey)}
	}
	return proxy.Assignment{AccountID: grant.AccountID,
		Credential: proxy.OAuth(grant.AccessToken)}
}

// renewGrants refreshes the credential of every account a live session is seeded on, and
// rewrites that session's namespace. Claude Code watches the file's modification time and
// re-reads it, so a run outliving its access token keeps going.
func (a *Agent) renewGrants(ctx context.Context) {
	now := a.now()
	a.mu.Lock()
	seeded := map[string][]string{}
	for id, session := range a.sessions {
		// Keyed on the seeded account, not the serving one: a rotation moves who serves
		// the session, and reseeding from that would drag its identity across an
		// organisation boundary.
		seeded[session.record.SeededAccountID] = append(seeded[session.record.SeededAccountID], id)
	}
	a.mu.Unlock()

	for accountID, sessionIDs := range seeded {
		a.mu.Lock()
		grant, cached := a.grants[accountID]
		a.mu.Unlock()
		if cached && grant.usable(now.Add(renewBefore)) {
			continue
		}
		fresh, err := a.grantFor(ctx, accountID, renewBefore)
		if err != nil {
			a.log("could not renew the credential for %s: %v", accountID, err)
			continue
		}
		for _, sessionID := range sessionIDs {
			if err := Seed(a.config.Namespace(sessionID), fresh, a.now()); err != nil {
				a.log("could not reseed session %s: %v", sessionID, err)
			}
		}
	}
}

func (a *Agent) reap() {
	a.mu.Lock()
	var gone []*live
	for id, session := range a.sessions {
		if !Alive(session.record.PID) {
			gone = append(gone, session)
			delete(a.sessions, id)
		}
	}
	sessions := a.recordsLocked()
	a.mu.Unlock()

	if len(gone) == 0 {
		return
	}
	for _, session := range gone {
		if session.proxy != nil {
			_ = session.proxy.Close()
		}
		if err := Clear(a.config.Namespace(session.record.ID)); err != nil {
			a.log("%v", err)
		}
		a.log("session %s ended", session.record.ID)
	}
	if err := a.store.Save(sessions); err != nil {
		a.log("could not write the sessions file: %v", err)
	}
}

// recover re-adopts the sessions that outlived the last run. Their ports are already
// baked into their ANTHROPIC_BASE_URL, so each proxy has to come back on the same one.
func (a *Agent) recover() {
	stored, err := a.store.Load()
	if err != nil {
		a.log("could not read the sessions file: %v", err)
		return
	}
	kept := make([]Session, 0, len(stored))
	for _, record := range stored {
		if !Alive(record.PID) {
			if err := Clear(a.config.Namespace(record.ID)); err != nil {
				a.log("%v", err)
			}
			continue
		}
		bound, err := a.startProxy(record)
		if err != nil {
			// Its base URL names a port nothing is listening on, so the run is finished
			// whatever we do. Dropping it without clearing the namespace would leave a
			// live access token on disk with nothing left to remove it.
			a.log("session %s: could not rebind port %d, ending it: %v",
				record.ID, record.Port, err)
			if err := Clear(a.config.Namespace(record.ID)); err != nil {
				a.log("%v", err)
			}
			continue
		}
		a.mu.Lock()
		a.sessions[record.ID] = bound
		a.mu.Unlock()
		kept = append(kept, record)
		a.log("session %s recovered on port %d", record.ID, record.Port)
	}
	if len(kept) != len(stored) {
		if err := a.store.Save(kept); err != nil {
			a.log("could not write the sessions file: %v", err)
		}
	}
}

func (a *Agent) startProxy(record Session) (*live, error) {
	upstream, err := url.Parse(a.config.Agent.Upstream)
	if err != nil {
		return nil, fmt.Errorf("upstream %q is not a url: %w", a.config.Agent.Upstream, err)
	}
	first, last := record.Port, record.Port
	if first == 0 {
		first, last = a.config.Agent.PortFirst, a.config.Agent.PortLast
	}
	started, err := proxy.Start(proxy.Options{
		SessionID: record.ID,
		Upstream:  upstream,
		Router:    a,
		Observe:   a.observe,
		Bill:      a.bill,
		Log:       a.log,
	}, first, last)
	if err != nil {
		return nil, err
	}
	record.Port = started.Port()
	return &live{record: record, proxy: started}, nil
}

func (a *Agent) recordsLocked() []Session {
	out := make([]Session, 0, len(a.sessions))
	for _, session := range a.sessions {
		out = append(out, session.record)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}
