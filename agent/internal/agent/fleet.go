package agent

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"ccmuxagent/internal/client"
	"ccmuxd/wire"
)

// report hands ccmuxd this box's whole session list, which is what makes the runs here
// visible on the Mac's Sessions page. A report replaces rather than merges, so the agent
// has to be the only thing on the box that reports — one machine id, one list.
func (a *Agent) report(ctx context.Context) {
	a.mu.Lock()
	enabled := a.reportsOK
	sessions := a.machineSessionsLocked(a.now())
	a.mu.Unlock()
	if !a.config.Reports() || !enabled {
		return
	}
	if _, err := a.client.ReportSessions(ctx, a.machine.ID,
		wire.MachineReport{Label: a.machine.Label, Sessions: sessions}); err != nil {
		a.log("could not report sessions: %v", err)
	}
}

func (a *Agent) machineSessionsLocked(now time.Time) []wire.MachineSession {
	out := make([]wire.MachineSession, 0, len(a.sessions))
	for _, session := range a.sessions {
		record := session.record
		entry := wire.MachineSession{
			ID:                record.ID,
			AccountID:         record.AccountID,
			Name:              record.Name,
			Policy:            record.Model,
			Status:            statusOf(record, now),
			StartedSecondsAgo: now.Sub(record.StartedAt).Seconds(),
			SpendUSD:          record.SpendUSD,
		}
		if entry.Policy == "" {
			entry.Policy = "any"
		}
		if record.Directory != "" {
			entry.Directory = wire.Ptr(record.Directory)
		}
		if !record.LastRequestAt.IsZero() {
			entry.UpdatedSecondsAgo = wire.Ptr(now.Sub(record.LastRequestAt).Seconds())
		}
		if account, known := a.account(record.AccountID); known {
			entry.AccountLabel = account.DisplayName()
			entry.AccountFingerprint = account.APIKeyFingerprint
		}
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Derived from whether the proxy has carried a request lately, rather than read from the
// ~/.claude/sessions/<pid>.json file Claude Code writes. That file's shape is neither
// documented nor stable — measured on 2.1.272, a print-mode run on Linux carries `status`
// and a freshly started one on macOS does not — and a session's traffic is the thing we
// actually know about.
func statusOf(record Session, now time.Time) string {
	if record.LastRequestAt.IsZero() {
		return "waiting"
	}
	if now.Sub(record.LastRequestAt) < busyFor {
		return "busy"
	}
	return "idle"
}

// pushUsage hands over the minutes that have ended. A refusal keeps the spool: the
// buckets are immutable once sent, so re-sending is an upsert and costs nothing.
func (a *Agent) pushUsage(ctx context.Context) {
	a.mu.Lock()
	enabled := a.seriesOK
	a.mu.Unlock()
	if !a.config.Reports() || !enabled {
		return
	}
	batch := a.ledger.Batch()
	if len(batch) == 0 {
		return
	}
	if _, err := a.client.ReportUsage(ctx, a.machine.ID,
		wire.UsageReport{Label: a.machine.Label, Buckets: batch}); err != nil {
		var status *client.StatusError
		if errors.As(err, &status) && !status.Transient() {
			// A refusal of the report itself will not fix itself, and keeping it would
			// wedge every later minute behind it.
			a.log("ccmuxd refused %d usage buckets, dropping them: %v", len(batch), err)
			a.ledger.Acknowledge(batch)
			return
		}
		a.log("could not push usage, keeping it for the next tick: %v", err)
		return
	}
	a.ledger.Acknowledge(batch)
}

func (a *Agent) saveSpool() {
	spool, changed := a.ledger.TakeSpool()
	if !changed {
		return
	}
	data, err := json.Marshal(spool)
	if err != nil {
		a.log("could not encode the usage spool: %v", err)
		return
	}
	if err := writeAtomic(a.config.SpoolFile(), data, 0o600); err != nil {
		a.log("could not write the usage spool: %v", err)
	}
}

// Status is what `ccmux status` prints.
type Status struct {
	MachineID    string          `json:"machineID"`
	MachineLabel string          `json:"machineLabel"`
	Accounts     []AccountStatus `json:"accounts"`
	Sessions     []SessionStatus `json:"sessions"`
	PendingUsage int             `json:"pendingUsageBuckets"`
	// The group runs here are given accounts from; absent means accounts in no group.
	Group string `json:"group,omitempty"`
	// Why a run without --group is refused while Group cannot be resolved.
	GroupError string `json:"groupError,omitempty"`
}

type AccountStatus struct {
	ID       string             `json:"id"`
	Label    string             `json:"label"`
	Kind     wire.AccountKind   `json:"kind"`
	Health   wire.AccountHealth `json:"health"`
	Windows  []wire.UsageWindow `json:"windows"`
	AgeSecs  float64            `json:"usageAgeSeconds"`
	Sessions int                `json:"sessions"`
	Group    string             `json:"group,omitempty"`
	// Why this box will not send work to the account; absent when it will.
	Unusable string `json:"unusable,omitempty"`
	// Why ccmux will not pick it for a run on its own, though --account still can.
	NotAutomatic string `json:"notAutomatic,omitempty"`
}

type SessionStatus struct {
	ID        string  `json:"id"`
	PID       int     `json:"pid"`
	Port      int     `json:"port"`
	AccountID string  `json:"accountID"`
	SeededAs  string  `json:"seededAccountID"`
	Group     string  `json:"group,omitempty"`
	Model     string  `json:"model,omitempty"`
	Name      string  `json:"name,omitempty"`
	Status    string  `json:"status"`
	Requests  int     `json:"requests"`
	SpendUSD  float64 `json:"spendUSD"`
}

func (a *Agent) Status() Status {
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	status := Status{
		MachineID:    a.machine.ID,
		MachineLabel: a.machine.Label,
		PendingUsage: a.ledger.Pending(),
	}
	var groupID string
	if wanted := a.wantedGroup(""); wanted != "" {
		group, err := a.resolveGroupLocked(wanted)
		status.Group, groupID = group.Name, group.ID
		if err != nil {
			// Matches no account, which is also all a launch would find.
			status.Group, groupID, status.GroupError = wanted, wanted, err.Error()
		}
	}
	perAccount := map[string]int{}
	for _, session := range a.sessions {
		perAccount[session.record.AccountID]++
	}
	for _, account := range a.accounts {
		entry := AccountStatus{ID: account.ID, Label: account.DisplayName(),
			Kind: account.Kind, Health: account.Health, Sessions: perAccount[account.ID],
			Unusable:     a.unusableLocked(account),
			NotAutomatic: a.unchosenLocked(account, groupID)}
		if in := a.groupOfLocked(account); in != "" {
			entry.Group = a.groupNameLocked(in)
		}
		if snapshot, known := a.usage[account.ID]; known {
			entry.Windows = snapshot.Windows
			entry.AgeSecs = now.Sub(snapshot.FetchedAt).Seconds()
		}
		status.Accounts = append(status.Accounts, entry)
	}
	for _, session := range a.sessions {
		record := session.record
		status.Sessions = append(status.Sessions, SessionStatus{
			ID: record.ID, PID: record.PID, Port: record.Port,
			AccountID: record.AccountID, SeededAs: record.SeededAccountID,
			Group: a.groupNameLocked(record.GroupID), Model: record.Model,
			Name: record.Name, Status: statusOf(record, now),
			Requests: record.Requests, SpendUSD: record.SpendUSD,
		})
	}
	sort.Slice(status.Sessions, func(i, j int) bool {
		return status.Sessions[i].ID < status.Sessions[j].ID
	})
	return status
}
