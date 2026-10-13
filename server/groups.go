package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
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
	r.pruneMembershipsLocked()
}

// pruneMembershipsLocked drops memberships of groups that no longer exist, and writes
// every account's in both spellings, whichever it was read in.
func (r *Registry) pruneMembershipsLocked() {
	for id, account := range r.accounts {
		kept := []string{}
		for _, group := range account.Groups() {
			if _, exists := r.groups[group]; exists {
				kept = append(kept, group)
			}
		}
		account.SetGroups(kept)
		r.accounts[id] = account
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

// changeGroups runs change under the lock and saves when it changed something, refusing
// while the groups file cannot be read.
func (r *Registry) changeGroups(change func() (changed bool, err error)) error {
	r.mu.Lock()
	changed, err := false, ErrGroupsUnavailable
	if !r.groupsUnreadable {
		changed, err = change()
	}
	r.mu.Unlock()
	if err == nil && changed {
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
	err = r.changeGroups(func() (bool, error) {
		if existing, ok := r.groupNamedLocked(name); ok {
			group = existing
			return false, nil
		}
		group, created = SubscriptionGroup{ID: id, Name: name}, true
		r.groups[id] = group
		return true, nil
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
	err = r.changeGroups(func() (bool, error) {
		var ok bool
		if group, ok = r.groups[id]; !ok {
			return false, notFound("no group %s", id)
		}
		if other, taken := r.groupNamedLocked(name); taken && other.ID != id {
			return false, rejected("a group named %q already exists", other.Name)
		}
		group.Name = name
		r.groups[id] = group
		return true, nil
	})
	return group, err
}

// DeleteGroup takes it off every account; one in no other group becomes ungrouped.
func (r *Registry) DeleteGroup(id string) error {
	var name string
	err := r.changeGroups(func() (bool, error) {
		group, ok := r.groups[id]
		if !ok {
			return false, notFound("no group %s", id)
		}
		name = group.Name
		delete(r.groups, id)
		r.pruneMembershipsLocked()
		return true, nil
	})
	if err == nil {
		logInfo("deleted group %s", name)
	}
	return err
}

// SetMembership adds the account to the group or takes it out, leaving its other groups
// alone. One membership per call, under the lock, so two machines editing one account at
// once cannot undo each other.
func (r *Registry) SetMembership(groupID, accountID string, member bool) (RemoteAccount, error) {
	var account RemoteAccount
	err := r.changeGroups(func() (bool, error) {
		if r.accountsUnreadable {
			return false, ErrAccountsUnavailable
		}
		var ok bool
		if account, ok = r.accounts[accountID]; !ok {
			return false, notFound("no account %s", accountID)
		}
		if _, ok := r.groups[groupID]; !ok {
			return false, notFound("no group %s", groupID)
		}
		if account.InGroup(groupID) == member {
			return false, nil
		}
		groups := account.Groups()
		if member {
			groups = append(groups, groupID)
		} else {
			groups = slices.DeleteFunc(slices.Clone(groups),
				func(g string) bool { return g == groupID })
		}
		account.SetGroups(groups)
		r.accounts[accountID] = account
		return true, nil
	})
	return account, err
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
		var groups []string
		if *update.GroupID != "" {
			groups = []string{*update.GroupID}
		}
		account.SetGroups(groups)
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
