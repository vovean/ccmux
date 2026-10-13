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
	"strings"
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
	// How often ccmuxd's features are re-read, so an upgrade is noticed without a restart.
	probeEvery = 10 * time.Minute
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

	mu       sync.Mutex
	sessions map[string]*live
	accounts []wire.RemoteAccount
	usage    map[string]*rules.Snapshot
	grants   map[string]Grant
	// Organisations — or, for an account with none, accounts — that refused OAuth this
	// run. Held until the agent restarts, which is also how one is tried again.
	refusing   map[string]bool
	reportsOK  bool
	seriesOK   bool
	groupsOK   bool
	probedAt   time.Time
	lastReport string
	// The last group list ccmuxd answered with; groupsKnown is whether it ever has.
	groups      []wire.SubscriptionGroup
	groupsKnown bool
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
		refusing: map[string]bool{},
	}, nil
}

func (a *Agent) Machine() Machine { return a.machine }

// ErrNoAccount is a launch refused because nothing in the pool can serve the model. The
// caller turns it into an exit code an application can queue on.
type ErrNoAccount struct {
	Model string
	// The name of the group the launch was limited to, if any.
	Group string
	// When some account frees up. Zero when nothing known can ever serve it.
	At time.Time
}

func (e *ErrNoAccount) Error() string {
	what := e.Model
	if what == "" {
		what = "this request"
	}
	who := "no account"
	if e.Group != "" {
		who = "no account in group " + e.Group
	}
	if e.At.IsZero() {
		return fmt.Sprintf("%s can serve %s, and none has a known reset", who, what)
	}
	return fmt.Sprintf("%s can serve %s until %s", who, what,
		e.At.UTC().Format(time.RFC3339))
}

// Start reads the pool, recovers the sessions that outlived the last run, and returns.
func (a *Agent) Start(ctx context.Context) error {
	if err := a.probe(ctx); err != nil {
		return fmt.Errorf("could not reach ccmuxd: %w", err)
	}
	a.mu.Lock()
	reports := a.reportsOK && a.seriesOK
	a.mu.Unlock()
	if a.config.Reports() && !reports {
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
	a.warnUnmatchedExclusions()
	a.warnUnmatchedGroup()
	a.recover()
	return nil
}

// probe reads what this ccmuxd can do.
func (a *Agent) probe(ctx context.Context) error {
	health, err := a.client.Health(ctx)
	if err != nil {
		return err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.reportsOK = client.Supports(health, wire.FeatureSessions)
	a.seriesOK = client.Supports(health, wire.FeatureUsageSeries)
	a.groupsOK = client.Supports(health, wire.FeatureGroups)
	a.probedAt = a.now()
	return nil
}

// A typo in exclude_accounts excludes nothing, which is the failure it exists to prevent.
func (a *Agent) warnUnmatchedExclusions() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, name := range a.config.Agent.ExcludeAccounts {
		matched := false
		for _, account := range a.accounts {
			if names(account, name, true) {
				matched = true
				break
			}
		}
		if !matched {
			a.log("exclude_accounts: %q matches no account on the server", name)
		}
	}
}

func (a *Agent) warnUnmatchedGroup() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if name := a.wantedGroup(""); name != "" {
		if _, err := a.resolveGroupLocked(name); err != nil {
			a.log("%v; runs without --group are refused until that changes", err)
		}
	}
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
	a.mu.Lock()
	due := a.now().Sub(a.probedAt) >= probeEvery
	a.mu.Unlock()
	if due {
		if err := a.probe(ctx); err != nil {
			a.log("could not read ccmuxd's features: %v", err)
		}
	}
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

// refresh re-reads the account list, the groups and each account's usage from ccmuxd.
// Reading usage costs nothing upstream — ccmuxd answers from its own cache and does the
// real polling.
func (a *Agent) refresh(ctx context.Context) error {
	accounts, err := a.client.Accounts(ctx)
	if err != nil {
		return err
	}
	// Read after the accounts, so a group an account was just put in is already listed.
	a.mu.Lock()
	groupsOK := a.groupsOK
	a.mu.Unlock()
	var groups []wire.SubscriptionGroup
	var groupsErr error
	if groupsOK {
		if groups, groupsErr = a.client.Groups(ctx); groupsErr != nil {
			a.log("could not read the groups, keeping the last known: %v", groupsErr)
		}
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
	if groupsOK && groupsErr == nil {
		a.groups, a.groupsKnown = groups, true
	}
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

// names reports whether a person could mean this account by `name`: its id, label or
// email, and — when `organisation` — its organisation's name or uuid.
func names(account wire.RemoteAccount, name string, organisation bool) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	candidates := []string{account.ID, account.Label, deref(account.Email)}
	if organisation {
		candidates = append(candidates, deref(account.OrganizationName),
			deref(account.OrganizationUUID))
	}
	for _, candidate := range candidates {
		if candidate != "" && strings.EqualFold(candidate, name) {
			return true
		}
	}
	return false
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// The key a refusal is held under: the whole organisation when it is known, because the
// policy that refused one seat refuses every seat in it.
func refusalKey(account wire.RemoteAccount) string {
	if org := deref(account.OrganizationUUID); org != "" {
		return "org:" + org
	}
	return "account:" + account.ID
}

// unusableLocked says why this box will not send work to the account, or "" if it will.
func (a *Agent) unusableLocked(account wire.RemoteAccount) string {
	for _, name := range a.config.Agent.ExcludeAccounts {
		if names(account, name, true) {
			return fmt.Sprintf("excluded by exclude_accounts (%q)", name)
		}
	}
	if a.refusing[refusalKey(account)] || a.refusing["account:"+account.ID] {
		return "its organisation refuses OAuth for Claude Code"
	}
	return ""
}

// resolveLocked finds the account a person named: an exact id first, then a label or
// email. More than one match is an error rather than a guess, since it decides who pays.
func (a *Agent) resolveLocked(name string) (wire.RemoteAccount, error) {
	for _, account := range a.accounts {
		if account.ID == name {
			return account, nil
		}
	}
	var found []wire.RemoteAccount
	for _, account := range a.accounts {
		if names(account, name, false) {
			found = append(found, account)
		}
	}
	switch len(found) {
	case 0:
		return wire.RemoteAccount{}, fmt.Errorf("no account %q on the server", name)
	case 1:
		return found[0], nil
	}
	return wire.RemoteAccount{}, fmt.Errorf("%q names %d accounts; use an id from "+
		"`ccmux status --json`", name, len(found))
}

// usableNamedLocked is the account a person named, refused if this box does not use it.
func (a *Agent) usableNamedLocked(name string) (wire.RemoteAccount, error) {
	account, err := a.resolveLocked(name)
	if err != nil {
		return wire.RemoteAccount{}, err
	}
	return account, a.refuseUnusableLocked(account)
}

func (a *Agent) refuseUnusableLocked(account wire.RemoteAccount) error {
	if why := a.unusableLocked(account); why != "" {
		return fmt.Errorf("%s is not used on this box: %s", account.DisplayName(), why)
	}
	return nil
}

// unchosenLocked says why ccmux will not give the account to a run on its own, or "" if
// it will. The run is limited to group `groupID`, or with none to accounts in no group.
// Unlike unusableLocked, naming the account overrides it.
func (a *Agent) unchosenLocked(account wire.RemoteAccount, groupID string) string {
	if account.Kind == wire.KindAPIKey {
		return "API key — pin it with --account"
	}
	if !account.IsInRotation() {
		return "out of rotation"
	}
	// Membership as the server sent it: it clears memberships when it deletes a group, so
	// an id it still sends keeps the account reserved even before this box lists it.
	switch groups := account.Groups(); {
	case groupID == "" && len(groups) > 0:
		names := a.groupNamesLocked(groups)
		noun := "group "
		if len(names) > 1 {
			noun = "groups "
		}
		return "in " + noun + strings.Join(names, ", ")
	case groupID != "" && !account.InGroup(groupID):
		return "not in group " + a.groupNameLocked(groupID)
	}
	return ""
}

// refuseUnchosenLocked is refuseUnusableLocked for an account ccmux picked itself.
func (a *Agent) refuseUnchosenLocked(account wire.RemoteAccount, groupID string) error {
	if err := a.refuseUnusableLocked(account); err != nil {
		return err
	}
	if why := a.unchosenLocked(account, groupID); why != "" {
		return fmt.Errorf("%s is not chosen automatically: %s", account.DisplayName(), why)
	}
	return nil
}

func (a *Agent) groupNamesLocked(ids []string) []string {
	names := make([]string, 0, len(ids))
	for _, id := range ids {
		names = append(names, a.groupNameLocked(id))
	}
	return names
}

func (a *Agent) groupNameLocked(id string) string {
	for _, group := range a.groups {
		if group.ID == id {
			return group.Name
		}
	}
	return id
}

// wantedGroup is the group a launch asked for, else the box's.
func (a *Agent) wantedGroup(run string) string {
	if run = strings.TrimSpace(run); run != "" {
		return run
	}
	return strings.TrimSpace(a.config.Agent.Group)
}

// resolveGroupLocked finds a group by id, or by name ignoring case. Not knowing is an
// error rather than a reason to widen the pool: that would spend another group's accounts.
func (a *Agent) resolveGroupLocked(name string) (wire.SubscriptionGroup, error) {
	switch {
	case !a.groupsOK:
		return wire.SubscriptionGroup{}, fmt.Errorf("group %q: this ccmuxd has no groups "+
			"— upgrade it", name)
	case !a.groupsKnown:
		return wire.SubscriptionGroup{}, fmt.Errorf("group %q: ccmuxd's group list has "+
			"not been read yet", name)
	}
	for _, group := range a.groups {
		if group.ID == name {
			return group, nil
		}
	}
	for _, group := range a.groups {
		if strings.EqualFold(group.Name, name) {
			return group, nil
		}
	}
	return wire.SubscriptionGroup{}, fmt.Errorf("no group %q on the server", name)
}

// OrganizationRefused holds the account's organisation out of every pick on this box.
func (a *Agent) OrganizationRefused(accountID string) {
	a.mu.Lock()
	account, known := a.account(accountID)
	if !known {
		account = wire.RemoteAccount{ID: accountID}
	}
	key := refusalKey(account)
	already := a.refusing[key]
	a.refusing[key] = true
	a.mu.Unlock()
	if !already {
		a.log("%s: its organisation refuses OAuth for Claude Code; nothing on this box "+
			"goes to that organisation again until the agent restarts", account.DisplayName())
	}
}

// poolCopy is usageCopy narrowed to the accounts ccmux may pick on its own for a run
// limited to `groupID`. Lock held.
func (a *Agent) poolCopy(groupID string) (accounts []wire.RemoteAccount,
	usage map[string]*rules.Snapshot) {
	all, usage := a.usageCopy()
	for _, account := range all {
		if a.unusableLocked(account) == "" && a.unchosenLocked(account, groupID) == "" {
			accounts = append(accounts, account)
		}
	}
	return accounts, usage
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
