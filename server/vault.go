package main

import (
	"context"
	"sync"
	"time"
)

// Vault owns every account's credential and is the sole refresher.
//
// ccmux has one hard constraint: Anthropic rotates refresh tokens, so two independent
// refreshers on one lineage means whichever refreshes second is told `invalid_grant` and
// is logged out for good. Multiple lineages per account are fine; two holders of one are
// not. This server exists to be the single holder.
//
// The coalescing below is the same design as the Swift TokenVault, and for the same
// measured reason: look-up and insert must be one critical section, or two callers each
// see an empty slot, both POST the same refresh token, and the loser is told
// `invalid_grant` — marking a perfectly healthy account as needing re-login.
type Vault struct {
	client  *OAuthClient
	secrets SecretStore

	mu          sync.Mutex
	credentials map[string]Credential
	inFlight    map[string]*refreshCall
	nextID      uint64
	// Grants actually in flight, so shutdown can wait for them. Detaching the context
	// stops a cancelled caller killing a rotation; it does not stop the process exiting
	// out from under one.
	//
	// A plain counter, not a sync.WaitGroup: Shutdown returns after its own deadline with
	// handlers still running, so a late Refresh can call Add while Wait is unblocking —
	// which panics, aborts the process, and kills every other grant in flight.
	activeGrants int
	drainWaiters []chan struct{}

	// Called when a refresh fails. Permanent failures are the re-login signal.
	OnRefreshFailure func(accountID string, err error)
	// Called when a rotated credential could not be written. That is a real
	// credential-loss risk: the rotation is live on Anthropic's side but only in memory
	// here, so a restart would come back holding a dead refresh token.
	OnPersistFailure func(accountID string, err error)
	OnCredentialSet  func(accountID string, c Credential)
}

type refreshCall struct {
	id     uint64
	done   chan struct{}
	result Credential
	ok     bool
}

// Refresh this far ahead of expiry so a request rarely has to wait on one.
const vaultRefreshLead = 10 * time.Minute

// A backstop above the OAuth client's own 30s request timeout, which is what actually
// governs a grant. Sitting below it would make this the real cap and cut rotations short.
const refreshGrantTimeout = 35 * time.Second

func NewVault(client *OAuthClient, secrets SecretStore) *Vault {
	return &Vault{
		client:      client,
		secrets:     secrets,
		credentials: map[string]Credential{},
		inFlight:    map[string]*refreshCall{},
	}
}

func (v *Vault) Load(accountIDs []string) {
	for _, id := range accountIDs {
		raw, ok, err := v.secrets.Read(id)
		if err != nil || !ok {
			continue
		}
		if credential, ok := ParseCredential(raw); ok {
			v.mu.Lock()
			v.credentials[id] = credential
			v.mu.Unlock()
		}
	}
}

// StoredAccountIDs is every account the secret store holds a credential for, whatever the
// accounts file happens to say.
func (v *Vault) StoredAccountIDs() []string {
	keys, err := v.secrets.Keys()
	if err != nil {
		return nil
	}
	return keys
}

func (v *Vault) Credential(accountID string) (Credential, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	c, ok := v.credentials[accountID]
	return c, ok
}

// Store writes unconditionally — adopt and sign-in, where the caller means to replace
// whatever is there. The map update and the secret write share one critical section for
// the same reason storeRotation does.
func (v *Vault) Store(accountID string, c Credential) {
	v.mu.Lock()
	v.credentials[accountID] = c
	err := v.writeSecretLocked(accountID, c)
	v.mu.Unlock()
	v.reportWrite(accountID, c, err)
}

// storeRotation replaces the credential only if the lineage we just refreshed is still
// the one on file.
//
// The test and the write are one critical section, and Forget deletes under the same
// lock. Checking first and storing after left a window where a DELETE could land between
// them, and the write would put a live refresh token back into the sealed file for an
// account that no longer exists — invisible to every client, never loaded again, orphaned
// for good.
//
// Identity, not mere presence: an account re-adopted mid-grant (a second Mac's adopt, or
// a browser sign-in completing) holds a *different* lineage, and overwriting it with this
// older rotation would silently discard the one the user just created.
func (v *Vault) storeRotation(accountID string, previous, rotated Credential) bool {
	v.mu.Lock()
	current, ok := v.credentials[accountID]
	if !ok || current.RefreshToken != previous.RefreshToken {
		v.mu.Unlock()
		return false
	}
	v.credentials[accountID] = rotated
	err := v.writeSecretLocked(accountID, rotated)
	v.mu.Unlock()

	// Callbacks outside the lock: they reach back into the registry, which takes its own.
	v.reportWrite(accountID, rotated, err)
	return true
}

// writeSecretLocked persists a credential. Caller holds v.mu. One retry, because the
// usual cause is transient and losing a rotation costs a re-login.
func (v *Vault) writeSecretLocked(accountID string, c Credential) error {
	err := v.secrets.Write(accountID, c.JSONString())
	if err != nil {
		err = v.secrets.Write(accountID, c.JSONString())
	}
	return err
}

func (v *Vault) reportWrite(accountID string, c Credential, err error) {
	if err != nil {
		logError("could not persist credential for %s: %v", accountID, err)
		if v.OnPersistFailure != nil {
			v.OnPersistFailure(accountID, err)
		}
	}
	if v.OnCredentialSet != nil {
		v.OnCredentialSet(accountID, c)
	}
}

func (v *Vault) Forget(accountID string) {
	// The secret delete happens under the same lock as the map delete, so a rotation
	// finishing concurrently cannot slip its write in afterwards. The inFlight entry is
	// deliberately left alone: clearing it would let a re-adopt inside this window start
	// a second grant on the same refresh token, which is the one failure the coalescing
	// exists to prevent. release() clears it when the grant finishes.
	v.mu.Lock()
	delete(v.credentials, accountID)
	_ = v.secrets.Delete(accountID)
	v.mu.Unlock()
}

// RefreshExpiring refreshes ahead of expiry so a token request rarely has to wait.
func (v *Vault) RefreshExpiring(ctx context.Context, accountIDs []string) {
	now := time.Now()
	for _, id := range accountIDs {
		credential, ok := v.Credential(id)
		if !ok {
			continue
		}
		remaining, known := credential.RemainingLife(now)
		if !known || remaining > vaultRefreshLead {
			continue
		}
		v.Refresh(ctx, id)
	}
}

// Refresh runs the refresh grant, coalescing concurrent callers onto one attempt so the
// loser gets the same rotated credential rather than nothing.
func (v *Vault) Refresh(ctx context.Context, accountID string) (Credential, bool) {
	call, mine := v.claim(accountID)
	if mine {
		v.run(ctx, accountID, call)
		v.release(accountID, call.id)
	} else {
		<-call.done
	}
	return call.result, call.ok
}

// Look-up and insert are one critical section — see the type comment.
func (v *Vault) claim(accountID string) (*refreshCall, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if running, ok := v.inFlight[accountID]; ok {
		return running, false
	}
	v.nextID++
	call := &refreshCall{id: v.nextID, done: make(chan struct{})}
	v.inFlight[accountID] = call
	v.activeGrants++
	return call, true
}

func (v *Vault) run(ctx context.Context, accountID string, call *refreshCall) {
	defer v.grantFinished()
	defer close(call.done)

	existing, ok := v.Credential(accountID)
	if !ok {
		return
	}
	// Detached from the caller's context on purpose. A refresh grant rotates the token on
	// Anthropic's side the moment they process it; if the caller's context is cancelled
	// mid-flight — a client that hung up, its 20s timeout, a SIGTERM during a
	// housekeeping tick — the rotated credential is never read or stored, the next
	// refresh is told invalid_grant, and the account is permanently logged out. The Swift
	// original was immune by accident: it ran the grant in an unstructured Task, which
	// outlives the awaiting one.
	grantCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), refreshGrantTimeout)
	defer cancel()

	rotated, err := v.client.Refresh(grantCtx, existing)
	if err != nil {
		logWarn("refresh failed for account %s: %v", accountID, err)
		if v.OnRefreshFailure != nil {
			v.OnRefreshFailure(accountID, err)
		}
		return
	}
	if !v.storeRotation(accountID, existing, rotated) {
		logWarn("%s changed while its refresh was in flight; discarding the result",
			accountID)
		return
	}
	logInfo("refreshed credential for account %s", accountID)
	call.result, call.ok = rotated, true
}

// WaitForGrants blocks until every in-flight refresh has finished, or the deadline
// passes. Called on shutdown: a grant rotates the token on Anthropic's side the moment
// they process it, so exiting mid-flight loses the rotation and the next refresh is told
// invalid_grant — a `systemctl restart` is enough to kill a lineage.
func (v *Vault) WaitForGrants(timeout time.Duration) bool {
	v.mu.Lock()
	if v.activeGrants == 0 {
		v.mu.Unlock()
		return true
	}
	waiter := make(chan struct{})
	v.drainWaiters = append(v.drainWaiters, waiter)
	v.mu.Unlock()

	select {
	case <-waiter:
		return true
	case <-time.After(timeout):
		return false
	}
}

func (v *Vault) grantFinished() {
	v.mu.Lock()
	v.activeGrants--
	var waiters []chan struct{}
	if v.activeGrants == 0 {
		waiters, v.drainWaiters = v.drainWaiters, nil
	}
	v.mu.Unlock()
	for _, waiter := range waiters {
		close(waiter)
	}
}

// Only the caller that created the entry may clear it, or a finishing refresh could
// delete a newer one's slot and reopen the race it just closed.
func (v *Vault) release(accountID string, id uint64) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if running, ok := v.inFlight[accountID]; ok && running.id == id {
		delete(v.inFlight, accountID)
	}
}
