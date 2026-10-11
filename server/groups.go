package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"time"
)

var ErrGroupsUnavailable = errors.New("groups.json could not be read; groups are " +
	"unavailable until it is fixed")

const maxGroupNameLength = 64

func (r *Registry) loadGroups() {
	var stored []SubscriptionGroup
	raw, err := os.ReadFile(r.groupsFile)
	if errors.Is(err, os.ErrNotExist) {
		err = nil
	} else if err == nil {
		err = json.Unmarshal(raw, &stored)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err != nil {
		r.groupsUnreadable = true
		logError("could not read %s, groups are unavailable: %v", r.groupsFile, err)
		return
	}
	for _, group := range stored {
		r.groups[group.ID] = group
	}
	for id, account := range r.accounts {
		if group := account.Group(); group != "" && r.groups[group].ID == "" {
			account.GroupID = nil
			r.accounts[id] = account
		}
	}
}

func (r *Registry) Groups() ([]SubscriptionGroup, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.groupsUnreadable {
		return nil, ErrGroupsUnavailable
	}
	return r.groupListLocked(), nil
}

func (r *Registry) groupListLocked() []SubscriptionGroup {
	out := make([]SubscriptionGroup, 0, len(r.groups))
	for _, group := range r.groups {
		out = append(out, group)
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func (r *Registry) groupNamedLocked(name string) (SubscriptionGroup, bool) {
	for _, group := range r.groups {
		if strings.EqualFold(group.Name, name) {
			return group, true
		}
	}
	return SubscriptionGroup{}, false
}

func validGroupName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", rejected("a group needs a name")
	}
	if len([]rune(name)) > maxGroupNameLength {
		return "", rejected("a group name is at most %d characters", maxGroupNameLength)
	}
	return name, nil
}

// changeGroups runs change under the lock and saves when it succeeds, refusing while the
// groups file cannot be read.
func (r *Registry) changeGroups(change func() error) error {
	r.mu.Lock()
	err := ErrGroupsUnavailable
	if !r.groupsUnreadable {
		err = change()
	}
	r.mu.Unlock()
	if err == nil {
		r.persist()
	}
	return err
}

// CreateGroup answers with the existing group when the name is taken, so two machines
// creating the same group at once end up sharing one.
func (r *Registry) CreateGroup(name string) (SubscriptionGroup, error) {
	name, err := validGroupName(name)
	if err != nil {
		return SubscriptionGroup{}, err
	}
	id, err := randomURLSafe(12)
	if err != nil {
		return SubscriptionGroup{}, err
	}
	var group SubscriptionGroup
	created := false
	err = r.changeGroups(func() error {
		if existing, ok := r.groupNamedLocked(name); ok {
			group = existing
			return nil
		}
		group, created = SubscriptionGroup{ID: id, Name: name}, true
		r.groups[id] = group
		return nil
	})
	if created {
		logInfo("created group %s", name)
	}
	return group, err
}

func (r *Registry) RenameGroup(id, name string) (SubscriptionGroup, error) {
	name, err := validGroupName(name)
	if err != nil {
		return SubscriptionGroup{}, err
	}
	var group SubscriptionGroup
	err = r.changeGroups(func() error {
		var ok bool
		if group, ok = r.groups[id]; !ok {
			return notFound("no group %s", id)
		}
		if other, taken := r.groupNamedLocked(name); taken && other.ID != id {
			return rejected("a group named %q already exists", other.Name)
		}
		group.Name = name
		r.groups[id] = group
		return nil
	})
	return group, err
}

// DeleteGroup leaves its accounts ungrouped.
func (r *Registry) DeleteGroup(id string) error {
	var name string
	err := r.changeGroups(func() error {
		group, ok := r.groups[id]
		if !ok {
			return notFound("no group %s", id)
		}
		name = group.Name
		delete(r.groups, id)
		for accountID, account := range r.accounts {
			if account.Group() == id {
				account.GroupID = nil
				r.accounts[accountID] = account
			}
		}
		return nil
	})
	if err == nil {
		logInfo("deleted group %s", name)
	}
	return err
}

// UpdateAccount applies every field or none of them.
func (r *Registry) UpdateAccount(id string, update AccountUpdate) (RemoteAccount, error) {
	r.mu.Lock()
	account, err := r.updatedAccountLocked(id, update)
	if err == nil {
		r.accounts[id] = account
	}
	r.mu.Unlock()
	if err != nil {
		return RemoteAccount{}, err
	}
	r.persist()
	return account, nil
}

func (r *Registry) updatedAccountLocked(id string, update AccountUpdate) (RemoteAccount, error) {
	if r.accountsUnreadable {
		return RemoteAccount{}, ErrAccountsUnavailable
	}
	account, ok := r.accounts[id]
	if !ok {
		return RemoteAccount{}, notFound("no account %s", id)
	}
	if update.GroupID != nil && *update.GroupID != "" {
		if r.groupsUnreadable {
			return RemoteAccount{}, ErrGroupsUnavailable
		}
		if _, exists := r.groups[*update.GroupID]; !exists {
			return RemoteAccount{}, notFound("no group %s", *update.GroupID)
		}
	}
	if update.Label != nil {
		account.Label = strings.TrimSpace(*update.Label)
	}
	if update.InRotation != nil {
		account.InRotation = ptr(*update.InRotation)
	}
	if update.MonthlyBudgetUSD != nil {
		account.MonthlyBudgetUSD = positiveOrNil(update.MonthlyBudgetUSD)
	}
	if update.GroupID != nil {
		account.GroupID = nil
		if *update.GroupID != "" {
			account.GroupID = ptr(*update.GroupID)
		}
	}
	return account, nil
}

func positiveOrNil(value *float64) *float64 {
	if value == nil || *value <= 0 {
		return nil
	}
	return ptr(*value)
}

// RefreshUsage polls now unless this account was polled within forcedPollFloor, and
// answers with whatever is freshest either way.
func (r *Registry) RefreshUsage(ctx context.Context, accountID string) (RemoteUsage, bool) {
	r.mu.Lock()
	account, ok := r.accounts[accountID]
	due := false
	if ok && pollable(account) {
		last := r.lastForcedPoll[accountID]
		if snapshot := r.usage[accountID]; snapshot != nil &&
			snapshot.LastEndpointFetch.After(last) {
			last = snapshot.LastEndpointFetch
		}
		if time.Since(last) >= forcedPollFloor {
			due = true
			r.lastForcedPoll[accountID] = time.Now()
		}
	}
	r.mu.Unlock()
	if due {
		r.poll(ctx, accountID)
	}
	return r.Usage(accountID)
}
