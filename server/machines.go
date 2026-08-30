package main

import (
	"sort"
	"strings"
	"sync"
	"time"
)

// What every Mac is running, so one of them can show the others' sessions.
//
// Two properties do all the work here. A report is a whole snapshot rather than a delta,
// so an ended session is simply absent from the next one — which makes a clean exit, a
// `kill -9` and a closed lid indistinguishable, and means nothing ever has to be reaped
// per session. And staleness is per machine, not per session: there is no pid to poll
// from another host, so the only honest liveness signal is when that host last spoke.
//
// Held in memory only. Every machine re-reports within a tick, so a restart costs a few
// seconds of blank screens and buys no file to corrupt, nothing to encrypt at rest and no
// growth on a box with 961 MB of RAM.
type MachineStore struct {
	mu       sync.Mutex
	machines map[string]*machineEntry
}

type machineEntry struct {
	label      string
	sessions   []MachineSession
	reportedAt time.Time
}

const (
	// A machine that has gone quiet for this long is forgotten. Clients stop showing one
	// long before that; this is only about not holding a laptop that never comes back.
	machineTTL = 24 * time.Hour
	// Ceilings, because the daemon runs under MemoryMax=192M next to the VPN processes.
	// The body cap in decodeBody bounds one request; these bound the accumulation.
	maxMachines           = 32
	maxSessionsPerMachine = 128
	maxMachineIDRunes     = 128
	maxFieldRunes         = 256
	// A century. Ages arrive as bare float64 and are formatted straight into a UI, where
	// the conversion to an integer traps on NaN and on anything past Int.max — so they
	// are bounded here, at the one place every machine's report passes through.
	maxReportedSeconds = 100 * 365 * 24 * 3600
	// Well past any plausible spend on one session, and finite.
	maxReportedSpendUSD = 1e9
)

func NewMachineStore() *MachineStore {
	return &MachineStore{machines: map[string]*machineEntry{}}
}

// Report replaces everything known about one machine.
func (s *MachineStore) Report(machineID string, report MachineReport, now time.Time) {
	entry := &machineEntry{
		label:      clean(report.Label, maxFieldRunes),
		sessions:   sanitiseSessions(report.Sessions),
		reportedAt: now,
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	if _, known := s.machines[machineID]; !known {
		s.evictOldestLocked(maxMachines - 1)
	}
	s.machines[machineID] = entry
}

// Snapshots returns every machine, the caller's own included.
//
// Deliberately not filtered here: a GET carries no machine identity — the basic-auth
// credential is shared — so the client has to drop its own id anyway. One rule on the
// client beats two behaviours on the server.
func (s *MachineStore) Snapshots(now time.Time) []MachineSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)

	out := make([]MachineSnapshot, 0, len(s.machines))
	for id, entry := range s.machines {
		age := now.Sub(entry.reportedAt).Seconds()
		if age < 0 {
			age = 0
		}
		sessions := entry.sessions
		if sessions == nil {
			// Go marshals a nil slice as null, which the client's non-optional array
			// throws on rather than reading as empty.
			sessions = []MachineSession{}
		}
		out = append(out, MachineSnapshot{
			MachineID: id, Label: entry.label, Sessions: sessions, AgeSeconds: age,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		left, right := strings.ToLower(out[i].Label), strings.ToLower(out[j].Label)
		if left != right {
			return left < right
		}
		return out[i].MachineID < out[j].MachineID
	})
	return out
}

func (s *MachineStore) Forget(machineID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, known := s.machines[machineID]
	delete(s.machines, machineID)
	return known
}

func (s *MachineStore) Count(now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	return len(s.machines)
}

func (s *MachineStore) pruneLocked(now time.Time) {
	for id, entry := range s.machines {
		if now.Sub(entry.reportedAt) > machineTTL {
			delete(s.machines, id)
		}
	}
}

func (s *MachineStore) evictOldestLocked(limit int) {
	for len(s.machines) > limit {
		oldestID, oldest := "", time.Time{}
		for id, entry := range s.machines {
			if oldestID == "" || entry.reportedAt.Before(oldest) {
				oldestID, oldest = id, entry.reportedAt
			}
		}
		delete(s.machines, oldestID)
	}
}

// ValidMachineID keeps an id that will be used as a map key and echoed back to every
// other client within something a UI can show.
func ValidMachineID(id string) bool {
	// Blank rather than empty: a path of "%20" decodes to a space, which would otherwise
	// be a perfectly valid map key that no UI could render.
	if strings.TrimSpace(id) == "" || len([]rune(id)) > maxMachineIDRunes {
		return false
	}
	return strings.IndexFunc(id, func(r rune) bool { return r < 0x20 || r == 0x7f }) < 0
}

func sanitiseSessions(sessions []MachineSession) []MachineSession {
	if len(sessions) > maxSessionsPerMachine {
		sessions = sessions[:maxSessionsPerMachine]
	}
	out := make([]MachineSession, 0, len(sessions))
	for _, session := range sessions {
		session.ID = clean(session.ID, maxFieldRunes)
		session.AccountID = clean(session.AccountID, maxFieldRunes)
		session.AccountLabel = clean(session.AccountLabel, maxFieldRunes)
		session.Name = clean(session.Name, maxFieldRunes)
		session.Policy = clean(session.Policy, maxFieldRunes)
		session.Status = clean(session.Status, maxFieldRunes)
		if session.Directory != nil {
			session.Directory = ptr(clean(*session.Directory, maxFieldRunes))
		}
		if session.AccountFingerprint != nil {
			session.AccountFingerprint = ptr(clean(*session.AccountFingerprint,
				maxFieldRunes))
		}
		session.StartedSecondsAgo = clampSeconds(session.StartedSecondsAgo)
		if session.UpdatedSecondsAgo != nil {
			session.UpdatedSecondsAgo = ptr(clampSeconds(*session.UpdatedSecondsAgo))
		}
		session.SpendUSD = clampFloat(session.SpendUSD, 0, maxReportedSpendUSD)
		out = append(out, session)
	}
	return out
}

func clampSeconds(value float64) float64 {
	return clampFloat(value, 0, maxReportedSeconds)
}

// NaN fails every comparison, so it is caught by the fallthrough rather than by a test
// against the bounds — which would let it straight past.
func clampFloat(value, low, high float64) float64 {
	switch {
	case value > low && value < high:
		return value
	case value >= high:
		return high
	default:
		return low
	}
}

// clean is what every string from a client goes through. A machine id with a control
// character in it is refused outright; these fields cannot be refused without dropping a
// legitimate report, so they are stripped instead — each one is rendered verbatim in every
// other Mac's window, where a newline or a NUL is at best confusing.
func clean(value string, limit int) string {
	return clampRunes(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value), limit)
}

// Truncated by rune, not by byte: cutting a multi-byte character in half produces a
// string that is no longer valid UTF-8, and json.Marshal replaces it with U+FFFD.
func clampRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
