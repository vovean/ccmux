package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
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

func rejected(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrRejected, fmt.Sprintf(format, args...))
}

// RejectionMessage strips the sentinel so the client sees the human half.
func RejectionMessage(err error) string {
	return strings.TrimPrefix(err.Error(), "rejected: ")
}

func NewRegistry(client *OAuthClient, secrets SecretStore, accountsFile string) *Registry {
	return &Registry{
		client:           client,
		vault:            NewVault(client, NewPrefixedStore(secrets, "oauth:")),
		apiKeys:          NewPrefixedStore(secrets, "apikey:"),
		accountsFile:     accountsFile,
		startedAt:        time.Now(),
		accounts:         map[string]RemoteAccount{},
		usage:            map[string]*UsageSnapshot{},
		logins:           map[string]*pendingLogin{},
		lastTokenRequest: map[string]time.Time{},
	}
}

func (r *Registry) Bootstrap() {
	stored := loadAccountsFile(r.accountsFile)
	subscriptionIDs := []string{}
	r.mu.Lock()
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
}

func (r *Registry) Health() HealthResponse {
	r.mu.Lock()
	defer r.mu.Unlock()
	return HealthResponse{
		APIVersion:    apiVersion,
		Accounts:      len(r.accounts),
		UptimeSeconds: time.Since(r.startedAt).Seconds(),
	}
}

func (r *Registry) List() []RemoteAccount {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.listLocked()
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

func (r *Registry) FinishLogin(ctx context.Context, req LoginFinishRequest) (RemoteAccount, error) {
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
	return r.adoptCredential(ctx, credential, "")
}

func (r *Registry) pruneLoginsLocked() {
	cutoff := time.Now().Add(-loginTTL)
	for id, login := range r.logins {
		if login.startedAt.Before(cutoff) {
			delete(r.logins, id)
		}
	}
}

func (r *Registry) Adopt(ctx context.Context, req AdoptRequest) (RemoteAccount, error) {
	label := ""
	if req.Label != nil {
		label = *req.Label
	}
	if req.APIKey != nil && *req.APIKey != "" {
		return r.adoptAPIKey(ctx, *req.APIKey, label)
	}
	if req.CredentialJSON == nil {
		return RemoteAccount{}, rejected("adopt needs either credentialJSON or apiKey")
	}
	credential, ok := ParseCredential(*req.CredentialJSON)
	if !ok {
		return RemoteAccount{}, rejected("adopt needs either credentialJSON or apiKey")
	}
	return r.adoptCredential(ctx, credential, label)
}

func (r *Registry) adoptCredential(ctx context.Context, credential Credential,
	label string) (RemoteAccount, error) {
	identity, err := r.client.Profile(ctx, credential.AccessToken)
	if err != nil {
		return RemoteAccount{}, rejected("%v", err)
	}

	r.mu.Lock()
	account, exists := r.accounts[identity.UUID]
	if !exists {
		fallback := label
		if fallback == "" {
			fallback = identity.Email
		}
		if fallback == "" {
			fallback = identity.UUID
		}
		account = RemoteAccount{ID: identity.UUID, Label: fallback}
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

func (r *Registry) adoptAPIKey(ctx context.Context, key, label string) (RemoteAccount, error) {
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
	r.mu.Lock()
	account, ok := r.accounts[accountID]
	if ok {
		delete(r.accounts, accountID)
		delete(r.usage, accountID)
		delete(r.lastTokenRequest, accountID)
	}
	r.mu.Unlock()
	if !ok {
		return rejected("no account %s", accountID)
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
		if account.Kind != KindSubscription || account.Health == HealthNeedsRelogin {
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

func (r *Registry) poll(ctx context.Context, accountID string) {
	credential, ok := r.vault.Credential(accountID)
	if !ok {
		return
	}
	windows, err := r.client.Usage(ctx, credential.AccessToken)
	r.record(accountID, windows, err)
}

func (r *Registry) record(accountID string, windows []UsageWindow, err error) {
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

	inUse := false
	if last, ok := r.lastTokenRequest[accountID]; ok {
		inUse = time.Since(last) < inUseWindow
	}
	plan := PlanPoll(inUse, previous, snapshot, pollThreshold, rateLimited, time.Now())
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
	r.mu.Unlock()
	saveAccountsFile(r.accountsFile, accounts)
}

var tempCounter atomic.Uint64

func atomicNextTemp() uint64 { return tempCounter.Add(1) }

func APIKeyFingerprint(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

func loadAccountsFile(path string) []RemoteAccount {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var accounts []RemoteAccount
	if err := json.Unmarshal(raw, &accounts); err != nil {
		logWarn("could not decode %s: %v", path, err)
		return nil
	}
	return accounts
}

func saveAccountsFile(path string, accounts []RemoteAccount) {
	encoded, err := json.MarshalIndent(accounts, "", "  ")
	if err != nil {
		logError("could not encode accounts: %v", err)
		return
	}
	// Unique per call: two concurrent saves on one fixed temp path open the same file
	// with O_TRUNC and interleave, and the result is an accounts.json that parses as
	// nothing on the next restart. persist() serialises our own writers; this covers
	// anything else that ever calls in.
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid()^int(atomicNextTemp()))
	if err := os.WriteFile(tmp, encoded, 0o600); err != nil {
		logError("could not write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		logError("could not save %s: %v", path, err)
	}
}
