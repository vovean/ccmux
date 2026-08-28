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

// A cap on a detached grant, so a wedged upstream cannot leave one running forever.
const refreshGrantTimeout = 60 * time.Second

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

func (v *Vault) Store(accountID string, c Credential) {
	v.mu.Lock()
	v.credentials[accountID] = c
	v.mu.Unlock()

	err := v.secrets.Write(accountID, c.JSONString())
	if err != nil {
		// One retry: the usual cause is transient, and losing a rotation costs a re-login.
		if err = v.secrets.Write(accountID, c.JSONString()); err != nil {
			logError("could not persist credential for %s: %v", accountID, err)
			if v.OnPersistFailure != nil {
				v.OnPersistFailure(accountID, err)
			}
		}
	}
	if v.OnCredentialSet != nil {
		v.OnCredentialSet(accountID, c)
	}
}

func (v *Vault) Forget(accountID string) {
	v.mu.Lock()
	delete(v.credentials, accountID)
	// Cleared so a later re-adopt claims a fresh slot rather than joining the doomed one.
	delete(v.inFlight, accountID)
	v.mu.Unlock()
	_ = v.secrets.Delete(accountID)
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
	return call, true
}

func (v *Vault) run(ctx context.Context, accountID string, call *refreshCall) {
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
	// Forgotten while the grant was in flight — a DELETE racing a refresh. Storing now
	// would write the rotated credential back into the sealed file after the account was
	// removed, leaving a live refresh token orphaned there indefinitely.
	if _, still := v.Credential(accountID); !still {
		logWarn("%s was removed while its refresh was in flight; discarding the result",
			accountID)
		return
	}
	v.Store(accountID, rotated)
	logInfo("refreshed credential for account %s", accountID)
	call.result, call.ok = rotated, true
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
