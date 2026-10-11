package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Registry is everything the server owns: the accounts, their refresh lineages, and the
// usage snapshots clients rank against.
//
// The point of centralising this is the constraint the client has always had to respect —
// multiple refresh lineages per account are fine, but two holders of one lineage are not.
// Here there is exactly one holder by construction: a refresh token enters through Adopt
// or FinishLogin and never leaves.
type Registry struct {
	client       *OAuthClient
	vault        *Vault
	apiKeys      SecretStore
	accountsFile string
	groupsFile   string
	startedAt    time.Time

	// Held across snapshot-and-write so persisted state cannot go backwards. Never taken
	// while holding mu.
	persistMu sync.Mutex

	mu       sync.Mutex
	accounts map[string]RemoteAccount
	usage    map[string]*UsageSnapshot
	logins   map[string]*pendingLogin
	// When a client last asked for this account's token. The server has no session
	// knowledge, so this stands in for "in use" when choosing a poll cadence.
	lastTokenRequest map[string]time.Time
	// A second opinion on whether an account is in use, supplied by the session store.
	activity func(accountID string) bool
	groups   map[string]SubscriptionGroup
	// Set when the file exists but cannot be decoded. It is then refused rather than
	// served or saved as empty: every client mirrors what it is told, so an empty answer
	// would ungroup, or delete, the same thing on every machine.
	groupsUnreadable   bool
	accountsUnreadable bool
	lastForcedPoll     map[string]time.Time
}

type pendingLogin struct {
	pkce      PKCE
	port      uint16
	accountID string
	startedAt time.Time
}

const (
	loginTTL = 10 * time.Minute
	// Hand out a token with at least this much life left, so a client that caches it does
	// not come straight back.
	minimumTokenLife = 10 * time.Minute
	// A token whose expiry the server does not know. Short, so the client re-asks.
	unknownTokenLife = 300 * time.Second
	// Treated as in use if a client asked for its token this recently.
	inUseWindow = 10 * time.Minute
	// Matches the client's default warn threshold; the server has no settings of its own
	// and only needs it to pick a poll cadence.
	pollThreshold = 3.0
)

// ErrRejected is a request the server refused: routed to 400 or 404, never an exit code.
var ErrRejected = errors.New("rejected")

var ErrNotFound = errors.New("not found")

func rejected(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrRejected, fmt.Sprintf(format, args...))
}

func notFound(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrNotFound, fmt.Sprintf(format, args...))
}

// RejectionMessage strips the sentinel so the client sees the human half.
func RejectionMessage(err error) string {
	message := strings.TrimPrefix(err.Error(), "rejected: ")
	return strings.TrimPrefix(message, "not found: ")
}

// The groups file sits beside accounts.json and is owned by the registry too, so deleting
// a group and clearing its members is one step under one lock.
func NewRegistry(client *OAuthClient, secrets SecretStore, accountsFile string) *Registry {
	return &Registry{
		client:           client,
		vault:            NewVault(client, NewPrefixedStore(secrets, "oauth:")),
		apiKeys:          NewPrefixedStore(secrets, "apikey:"),
		accountsFile:     accountsFile,
		groupsFile:       filepath.Join(filepath.Dir(accountsFile), "groups.json"),
		startedAt:        time.Now(),
		accounts:         map[string]RemoteAccount{},
		usage:            map[string]*UsageSnapshot{},
		logins:           map[string]*pendingLogin{},
		lastTokenRequest: map[string]time.Time{},
		groups:           map[string]SubscriptionGroup{},
		lastForcedPoll:   map[string]time.Time{},
	}
}

// SetActivitySource supplies a second opinion on whether an account is in use. Called
// once at startup; nil leaves the registry on token requests alone. The callback is
// invoked without the registry lock held, so it may not reach back into the registry.
func (r *Registry) SetActivitySource(inUse func(accountID string) bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.activity = inUse
}

func (r *Registry) Bootstrap() {
	// A crash between the write and the rename leaves a temp behind, and unique names
	// mean they accumulate rather than being reused. Swept here because startup is the
	// one moment no save of ours is in flight.
	sweepStaleTempFiles(r.accountsFile)
	sweepStaleTempFiles(r.groupsFile)

	stored, readable := loadAccountsFile(r.accountsFile)
	subscriptionIDs := []string{}
	r.mu.Lock()
	r.accountsUnreadable = !readable
	for _, account := range stored {
		r.accounts[account.ID] = account
		if account.Kind == KindSubscription {
			subscriptionIDs = append(subscriptionIDs, account.ID)
		}
	}
	r.mu.Unlock()

	r.vault.Load(subscriptionIDs)
	r.vault.OnRefreshFailure = r.recordRefreshFailure
	r.vault.OnPersistFailure = r.recordPersistFailure
	r.vault.OnCredentialSet = func(accountID string, _ Credential) { r.markHealthy(accountID) }

	// The sealed store is the authority on what we can actually serve. An account in the
	// file with no credential behind it would otherwise 404 on every token request with
	// nothing saying why.
	held := map[string]bool{}
	for _, id := range r.vault.StoredAccountIDs() {
		held[id] = true
	}
	r.mu.Lock()
	for id, account := range r.accounts {
		if account.Kind == KindSubscription && !held[id] {
			account.Health = HealthNeedsRelogin
			account.HealthDetail = ptr("no credential on the server")
			r.accounts[id] = account
			logWarn("account %s has no stored credential", id)
		}
	}
	count := len(r.accounts)
	r.mu.Unlock()
	logInfo("loaded %d account(s)", count)
	r.loadGroups()
}

// WaitForRefreshes blocks until no refresh grant is in flight, or the deadline passes.
func (r *Registry) WaitForRefreshes(timeout time.Duration) bool {
	return r.vault.WaitForGrants(timeout)
}

func (r *Registry) Health() HealthResponse {
	r.mu.Lock()
	defer r.mu.Unlock()
	return HealthResponse{
		APIVersion:    apiVersion,
		Accounts:      len(r.accounts),
		UptimeSeconds: time.Since(r.startedAt).Seconds(),
		Features:      serverFeatures,
	}
}

func (r *Registry) List() []RemoteAccount {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.listLocked()
}

var ErrAccountsUnavailable = errors.New("accounts.json could not be read; fix or restore " +
	"it and restart ccmuxd")

// Accounts is List for clients: refused while the file is unreadable, because a client
// that mirrors an empty list drops every account it has.
func (r *Registry) Accounts() ([]RemoteAccount, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.accountsUnreadable {
		return nil, ErrAccountsUnavailable
	}
	return r.listLocked(), nil
}

func (r *Registry) listLocked() []RemoteAccount {
	out := make([]RemoteAccount, 0, len(r.accounts))
	for _, account := range r.accounts {
		out = append(out, account)
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.ToLower(out[i].DisplayName()) < strings.ToLower(out[j].DisplayName())
	})
	return out
}

// Token hands out a live access token, refreshing first if what we hold is close to
// expiry.
//
// Never returns a refresh token. That is the invariant the whole design rests on, so it
// is enforced by what TokenGrant can carry rather than by remembering to strip a field.
func (r *Registry) Token(ctx context.Context, accountID string) (TokenGrant, bool) {
	r.mu.Lock()
	account, ok := r.accounts[accountID]
	if ok {
		r.lastTokenRequest[accountID] = time.Now()
	}
	r.mu.Unlock()
	if !ok {
		return TokenGrant{}, false
	}

	if account.Kind == KindAPIKey {
		key, found, err := r.apiKeys.Read(accountID)
		if err != nil || !found || key == "" {
			return TokenGrant{}, false
		}
		return TokenGrant{AccountID: accountID, Kind: KindAPIKey, APIKey: &key,
			Scopes: []string{}}, true
	}

	credential, ok := r.vault.Credential(accountID)
	if !ok {
		return TokenGrant{}, false
	}
	remaining, known := credential.RemainingLife(time.Now())
	if !known || remaining < minimumTokenLife {
		// A failed refresh still yields the old token: the API may honour it inside its
		// own grace period, and nil parks a live session for certain.
		if rotated, ok := r.vault.Refresh(ctx, accountID); ok {
			credential = rotated
		}
	}

	// A token still inside its lifetime is worth returning even when the refresh failed.
	// One that is already expired is not: the client would overwrite its own working
	// credential with it, so this refuses exactly as a missing credential does.
	if expiry, known := credential.RemainingLife(time.Now()); known && expiry <= 0 {
		logWarn("%s has no live access token and could not be refreshed", accountID)
		return TokenGrant{}, false
	}

	life := unknownTokenLife.Seconds()
	if remaining, known := credential.RemainingLife(time.Now()); known {
		life = remaining.Seconds()
		if life < 0 {
			life = 0
		}
	}
	grant := TokenGrant{
		AccountID:   accountID,
		Kind:        KindSubscription,
		AccessToken: &credential.AccessToken,
		ExpiresIn:   &life,
		Scopes:      credential.Scopes,
	}
	if grant.Scopes == nil {
		grant.Scopes = []string{}
	}
	if credential.SubscriptionType != "" {
		grant.SubscriptionType = &credential.SubscriptionType
	} else {
		grant.SubscriptionType = account.SubscriptionType
	}
	if credential.RateLimitTier != "" {
		grant.RateLimitTier = &credential.RateLimitTier
	} else {
		grant.RateLimitTier = account.RateLimitTier
	}
	return grant, true
}

func (r *Registry) Usage(accountID string) (RemoteUsage, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.accounts[accountID]; !ok {
		return RemoteUsage{}, false
	}
	snapshot, ok := r.usage[accountID]
	if !ok {
		return RemoteUsage{}, false
	}
	age := time.Since(snapshot.FetchedAt).Seconds()
	if age < 0 {
		age = 0
	}
	windows := snapshot.Windows
	if windows == nil {
		windows = []UsageWindow{}
	}
	return RemoteUsage{AccountID: accountID, Windows: windows, AgeSeconds: age}, true
}

// StartLogin begins a login. The PKCE pair is generated here so the verifier never leaves
// the server, which is what keeps the code the browser returns from being redeemable by
// anyone else.
func (r *Registry) StartLogin(req LoginStartRequest) (LoginStartResponse, error) {
	pkce, err := NewPKCE()
	if err != nil {
		return LoginStartResponse{}, err
	}
	loginID, err := randomURLSafe(16)
	if err != nil {
		return LoginStartResponse{}, err
	}

	hint := ""
	if req.LoginHint != nil {
		hint = *req.LoginHint
	}
	r.mu.Lock()
	r.pruneLoginsLocked()
	accountID := ""
	if req.AccountID != nil {
		accountID = *req.AccountID
		if hint == "" {
			if account, ok := r.accounts[accountID]; ok && account.Email != nil {
				hint = *account.Email
			}
		}
	}
	r.logins[loginID] = &pendingLogin{pkce: pkce, port: req.RedirectPort,
		accountID: accountID, startedAt: time.Now()}
	r.mu.Unlock()

	return LoginStartResponse{
		LoginID:      loginID,
		AuthorizeURL: AuthorizeURL(pkce, req.RedirectPort, hint),
		State:        pkce.State,
	}, nil
}

// writable refuses changes while accounts.json is unreadable: one made now would live in
// memory only, and vanish from every client after the restart that fixes the file.
func (r *Registry) writable() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.accountsUnreadable {
		return ErrAccountsUnavailable
	}
	return nil
}

func (r *Registry) FinishLogin(ctx context.Context, req LoginFinishRequest) (RemoteAccount, error) {
	if err := r.writable(); err != nil {
		return RemoteAccount{}, err
	}
	r.mu.Lock()
	r.pruneLoginsLocked()
	pending, ok := r.logins[req.LoginID]
	if ok {
		delete(r.logins, req.LoginID)
	}
	r.mu.Unlock()

	if !ok {
		return RemoteAccount{}, rejected("no login in flight for that id — it may have expired")
	}
	if req.State != nil && *req.State != pending.pkce.State {
		return RemoteAccount{}, rejected("sign-in state did not match; nothing was stored")
	}
	credential, err := r.client.Exchange(ctx, req.Code, pending.pkce, pending.port)
	if err != nil {
		return RemoteAccount{}, rejected("%v", err)
	}
	// Only for a new account: a re-login would otherwise put this machine's possibly
	// stale name over the shared one.
	initial := initialSettings{}
	if req.Label != nil {
		initial.label = strings.TrimSpace(*req.Label)
	}
	return r.adoptCredential(ctx, credential, "", initial)
}

func (r *Registry) pruneLoginsLocked() {
	cutoff := time.Now().Add(-loginTTL)
	for id, login := range r.logins {
		if login.startedAt.Before(cutoff) {
			delete(r.logins, id)
		}
	}
}

// Shared settings an adopt carries for an account the server does not have yet.
type initialSettings struct {
	label            string
	inRotation       *bool
	monthlyBudgetUSD *float64
}

func (s initialSettings) apply(account *RemoteAccount) {
	account.InRotation = s.inRotation
	account.MonthlyBudgetUSD = positiveOrNil(s.monthlyBudgetUSD)
}

func (r *Registry) Adopt(ctx context.Context, req AdoptRequest) (RemoteAccount, error) {
	if err := r.writable(); err != nil {
		return RemoteAccount{}, err
	}
	label := ""
	if req.Label != nil {
		label = *req.Label
	}
	initial := initialSettings{inRotation: req.InRotation, monthlyBudgetUSD: req.MonthlyBudgetUSD}
	if req.APIKey != nil && *req.APIKey != "" {
		return r.adoptAPIKey(ctx, *req.APIKey, label, initial)
	}
	if req.CredentialJSON == nil {
		return RemoteAccount{}, rejected("adopt needs either credentialJSON or apiKey")
	}
	credential, ok := ParseCredential(*req.CredentialJSON)
	if !ok {
		return RemoteAccount{}, rejected("adopt needs either credentialJSON or apiKey")
	}
	return r.adoptCredential(ctx, credential, label, initial)
}

func (r *Registry) adoptCredential(ctx context.Context, credential Credential,
	label string, initial initialSettings) (RemoteAccount, error) {
	identity, err := r.client.Profile(ctx, credential.AccessToken)
	if err != nil {
		return RemoteAccount{}, rejected("%v", err)
	}

	r.mu.Lock()
	account, exists := r.accounts[identity.UUID]
	if !exists {
		fallback := label
		if fallback == "" {
			fallback = initial.label
		}
		if fallback == "" {
			fallback = identity.Email
		}
		if fallback == "" {
			fallback = identity.UUID
		}
		account = RemoteAccount{ID: identity.UUID, Label: fallback}
		initial.apply(&account)
	}
	if label != "" {
		account.Label = label
	}
	if identity.Email != "" {
		account.Email = &identity.Email
	}
	if identity.OrganizationUUID != "" {
		account.OrganizationUUID = &identity.OrganizationUUID
	}
	if identity.OrganizationName != "" {
		account.OrganizationName = &identity.OrganizationName
	}
	// The profile is the fallback, not an afterthought: a token exchange can hand back a
	// credential with no plan on it, and a session seeded without one is read by Claude
	// Code as having no entitlements at all.
	if credential.SubscriptionType != "" {
		account.SubscriptionType = &credential.SubscriptionType
	} else if identity.SubscriptionType != "" {
		account.SubscriptionType = &identity.SubscriptionType
	}
	if credential.RateLimitTier != "" {
		account.RateLimitTier = &credential.RateLimitTier
	} else if identity.RateLimitTier != "" {
		account.RateLimitTier = &identity.RateLimitTier
	}
	account.Kind = KindSubscription
	account.Health = HealthOK
	account.HealthDetail = nil
	r.accounts[account.ID] = account
	r.mu.Unlock()

	r.vault.Store(account.ID, credential)
	r.persist()
	// Usage is fetched afterwards, not inline. Profile above already cost up to 15s and a
	// usage call costs another; a client that gives up at 20s while the server has
	// already stored the refresh token leaves both sides holding one lineage.
	go r.poll(context.Background(), account.ID)
	logInfo("adopted %s (%s)", account.DisplayName(), account.ID)
	return account, nil
}

func (r *Registry) adoptAPIKey(ctx context.Context, key, label string,
	initial initialSettings) (RemoteAccount, error) {
	if err := r.client.ValidateAPIKey(ctx, key); err != nil {
		return RemoteAccount{}, rejected("%v", err)
	}
	fingerprint := APIKeyFingerprint(key)

	r.mu.Lock()
	// Matched on the fingerprint, not the id: an API-key account's id is generated
	// locally and differs on every machine, so re-adopting the same key from a second Mac
	// must land on the existing record rather than duplicating it.
	var account RemoteAccount
	found := false
	for _, existing := range r.accounts {
		if existing.APIKeyFingerprint != nil && *existing.APIKeyFingerprint == fingerprint {
			account, found = existing, true
			break
		}
	}
	if !found {
		id, err := randomURLSafe(16)
		if err != nil {
			r.mu.Unlock()
			return RemoteAccount{}, err
		}
		name := label
		if name == "" {
			name = "API key"
		}
		account = RemoteAccount{ID: id, Label: name}
		initial.apply(&account)
	}
	if label != "" {
		account.Label = label
	}
	account.Kind = KindAPIKey
	account.Health = HealthOK
	account.HealthDetail = nil
	account.APIKeyFingerprint = &fingerprint
	r.accounts[account.ID] = account
	r.mu.Unlock()

	if err := r.apiKeys.Write(account.ID, key); err != nil {
		return RemoteAccount{}, err
	}
	r.persist()
	logInfo("adopted API key account %s", account.DisplayName())
	return account, nil
}

func (r *Registry) Remove(accountID string) error {
	if err := r.writable(); err != nil {
		return err
	}
	r.mu.Lock()
	account, ok := r.accounts[accountID]
	if ok {
		delete(r.accounts, accountID)
		delete(r.usage, accountID)
		delete(r.lastTokenRequest, accountID)
		delete(r.lastForcedPoll, accountID)
	}
	r.mu.Unlock()
	if !ok {
		return notFound("no account %s", accountID)
	}
	if account.Kind == KindAPIKey {
		_ = r.apiKeys.Delete(accountID)
	} else {
		r.vault.Forget(accountID)
	}
	r.persist()
	logInfo("removed %s", account.DisplayName())
	return nil
}

// Tick is one round of housekeeping: keep every lineage alive, and keep usage fresh
// enough for clients to rank against.
func (r *Registry) Tick(ctx context.Context) {
	r.mu.Lock()
	r.pruneLoginsLocked()
	var subscriptions []string
	for id, account := range r.accounts {
		if account.Kind == KindSubscription {
			subscriptions = append(subscriptions, id)
		}
	}
	r.mu.Unlock()

	r.vault.RefreshExpiring(ctx, subscriptions)
	r.pollDue(ctx)
}

func (r *Registry) pollDue(ctx context.Context) {
	now := time.Now()
	r.mu.Lock()
	var due []string
	for id, account := range r.accounts {
		if !pollable(account) {
			continue
		}
		snapshot, ok := r.usage[id]
		if !ok || snapshot.NextPollAt.IsZero() || !snapshot.NextPollAt.After(now) {
			due = append(due, id)
		}
	}
	r.mu.Unlock()

	for _, id := range due {
		r.poll(ctx, id)
	}
}

func pollable(account RemoteAccount) bool {
	return account.Kind == KindSubscription && account.Health != HealthNeedsRelogin
}

func (r *Registry) poll(ctx context.Context, accountID string) {
	credential, ok := r.vault.Credential(accountID)
	if !ok {
		return
	}
	windows, err := r.client.Usage(ctx, credential.AccessToken)
	r.record(accountID, windows, err)
}

func (r *Registry) record(accountID string, windows []UsageWindow, err error) {
	// Asked before the lock is taken. The callback is supplied from outside, and one that
	// reached back into the registry would block on a mutex this already holds.
	r.mu.Lock()
	activity := r.activity
	r.mu.Unlock()
	hasSession := activity != nil && activity(accountID)

	r.mu.Lock()
	defer r.mu.Unlock()

	previous := r.usage[accountID]
	// Stamped now, not left at the zero time: a first poll that fails would otherwise
	// report an age of two thousand years to every client that asked.
	snapshot := UsageSnapshot{FetchedAt: time.Now()}
	if previous != nil {
		snapshot = *previous
	}
	rateLimited := false
	if err != nil {
		snapshot.LastError = err.Error()
		rateLimited = statusOf(err) == 429
	} else {
		snapshot.Windows = windows
		snapshot.FetchedAt = time.Now()
		snapshot.LastEndpointFetch = time.Now()
		snapshot.LastError = ""
	}

	askedForToken := false
	if last, ok := r.lastTokenRequest[accountID]; ok {
		askedForToken = time.Since(last) < inUseWindow
	}
	// A delegated client caches its access token for hours, so a token request is a poor
	// liveness signal on its own; a reported session is a direct one.
	plan := PlanPoll(askedForToken || hasSession, previous, snapshot, pollThreshold,
		rateLimited, time.Now())
	// But only a token request earns the 60s branch. This is the sole poller for a
	// delegated account, and 60s is roughly double what the endpoint budgets per token —
	// spending it is what makes every window stale for an hour instead of five minutes.
	if hasSession && !askedForToken && plan.Interval < pollMinInterval {
		plan = PollPlan{Interval: pollMinInterval,
			NextPollAt: time.Now().Add(jitter(pollMinInterval))}
	}
	snapshot.NextPollAt = plan.NextPollAt
	r.usage[accountID] = &snapshot
}

func (r *Registry) recordRefreshFailure(accountID string, err error) {
	if !IsPermanent(err) {
		return
	}
	r.mu.Lock()
	if account, ok := r.accounts[accountID]; ok {
		account.Health = HealthNeedsRelogin
		account.HealthDetail = ptr(err.Error())
		r.accounts[accountID] = account
	}
	r.mu.Unlock()
	r.persist()
	logWarn("%s needs re-login: %v", accountID, err)
}

// A rotation live on Anthropic's side but not on disk means the next restart comes back
// holding a dead refresh token. Recorded on the account so it reaches every client, not
// just this process's stdout.
func (r *Registry) recordPersistFailure(accountID string, err error) {
	r.mu.Lock()
	if account, ok := r.accounts[accountID]; ok {
		account.HealthDetail = ptr("a rotated credential could not be saved: " + err.Error())
		r.accounts[accountID] = account
	}
	r.mu.Unlock()
	r.persist()
	logError("could not persist the rotated credential for %s — a restart will come back "+
		"with a dead refresh token: %v", accountID, err)
}

func (r *Registry) markHealthy(accountID string) {
	r.mu.Lock()
	account, ok := r.accounts[accountID]
	if !ok || account.Health != HealthNeedsRelogin {
		r.mu.Unlock()
		return
	}
	account.Health = HealthOK
	account.HealthDetail = nil
	r.accounts[accountID] = account
	r.mu.Unlock()
	r.persist()
}

// persist serialises writers. Two callers that snapshot and then race to the file can
// otherwise commit in the opposite order to their snapshots, silently dropping a
// just-adopted account or resurrecting a removed one — and the Swift original got this
// for free by being an actor.
func (r *Registry) persist() {
	r.persistMu.Lock()
	defer r.persistMu.Unlock()
	r.mu.Lock()
	accounts := r.listLocked()
	saveAccounts := !r.accountsUnreadable
	saveGroups := !r.groupsUnreadable
	groups := r.groupListLocked()
	r.mu.Unlock()
	if saveAccounts {
		saveJSONFile(r.accountsFile, accounts)
	}
	if saveGroups {
		saveJSONFile(r.groupsFile, groups)
	}
}

var tempCounter atomic.Uint64

func atomicNextTemp() uint64 { return tempCounter.Add(1) }

func APIKeyFingerprint(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func sweepStaleTempFiles(path string) {
	matches, err := filepath.Glob(path + ".*.tmp")
	if err != nil {
		return
	}
	for _, stale := range matches {
		if err := os.Remove(stale); err == nil {
			logInfo("removed a leftover temp file: %s", filepath.Base(stale))
		}
	}
}

// Readable is false when the file exists but cannot be used, as opposed to there being
// none yet.
func loadAccountsFile(path string) (accounts []RemoteAccount, readable bool) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, true
	}
	if err == nil {
		err = json.Unmarshal(raw, &accounts)
	}
	if err != nil {
		logError("could not read %s, refusing to serve or overwrite it: %v", path, err)
		return nil, false
	}
	return accounts, true
}

func saveJSONFile(path string, value any) {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		logError("could not encode %s: %v", filepath.Base(path), err)
		return
	}
	// Unique per call: two concurrent saves on one fixed temp path open the same file
	// with O_TRUNC and interleave, and the result is an accounts.json that parses as
	// nothing on the next restart. persist() serialises our own writers; this covers
	// anything else that ever calls in.
	// pid and counter as separate components: xor-ing them collides across processes
	// (100^3 == 101^2), and two ccmuxd sharing a data directory would race the temp file.
	tmp := fmt.Sprintf("%s.%d.%d.tmp", path, os.Getpid(), atomicNextTemp())
	if err := os.WriteFile(tmp, encoded, 0o600); err != nil {
		os.Remove(tmp)
		logError("could not write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		logError("could not save %s: %v", path, err)
	}
}
