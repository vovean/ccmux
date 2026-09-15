package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

// Session is one `claude -p` run the agent is keeping alive.
type Session struct {
	ID   string `json:"id"`
	PID  int    `json:"pid"`
	Port int    `json:"port"`
	// Who serves this session's requests right now.
	AccountID string `json:"accountID"`
	// Whose credential is in the namespace, which is how Claude Code decides what
	// organisation it is in. Distinct from AccountID: a rotation moves the serving
	// account only, because an organisation mandates managed plugins and crossing that
	// boundary mid-session makes a plugin that never loaded become required.
	SeededAccountID string    `json:"seededAccountID"`
	Model           string    `json:"model,omitempty"`
	Directory       string    `json:"cwd,omitempty"`
	Name            string    `json:"name,omitempty"`
	StartedAt       time.Time `json:"startedAt"`
	// Last time a request passed through this session's proxy. The status a Mac shows is
	// derived from this: `claude -p` writes no status of its own.
	LastRequestAt time.Time `json:"lastRequestAt,omitempty"`
	Requests      int       `json:"requests"`
	SpendUSD      float64   `json:"spendUSD"`
}

// Alive reports whether the process the session was started for is still running.
// Signal 0 checks for existence without delivering anything; EPERM means it exists and
// belongs to someone else, which for our own children cannot happen but is still alive.
func Alive(pid int) bool {
	if pid <= 1 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// Store is the sessions file. Small enough to rewrite whole, and rewritten atomically so
// a kill mid-write cannot leave the agent with no idea what is running.
type Store struct {
	path string
}

func NewStore(path string) *Store { return &Store{path: path} }

func (s *Store) Load() ([]Session, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var sessions []Session
	if err := json.Unmarshal(data, &sessions); err != nil {
		return nil, fmt.Errorf("could not read %s: %w", s.path, err)
	}
	// A record written before this field existed must not decode to an empty identity,
	// which would re-seed every live session on the next tick.
	for i := range sessions {
		if sessions[i].SeededAccountID == "" {
			sessions[i].SeededAccountID = sessions[i].AccountID
		}
	}
	return sessions, nil
}

func (s *Store) Save(sessions []Session) error {
	sorted := append([]Session(nil), sessions...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	data, err := json.MarshalIndent(sorted, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(s.path, append(data, '\n'), 0o600)
}

// writeAtomic writes through a temporary file in the same directory, so a reader either
// sees the old contents or the new ones and never a half-written file.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if err := temp.Chmod(mode); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

// Machine is how this box identifies itself to ccmuxd. The id is generated once and kept,
// because it is the key every session report replaces.
type Machine struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

func LoadMachine(path, label string) (Machine, error) {
	var machine Machine
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &machine); err == nil && machine.ID != "" {
			if label != "" && label != machine.Label {
				machine.Label = label
				_ = saveMachine(path, machine)
			}
			return machine, nil
		}
	}
	if label == "" {
		host, err := os.Hostname()
		if err != nil || host == "" {
			host = "linux-box"
		}
		label = host
	}
	machine = Machine{ID: newID(), Label: label}
	return machine, saveMachine(path, machine)
}

func saveMachine(path string, machine Machine) error {
	data, err := json.MarshalIndent(machine, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, append(data, '\n'), 0o600)
}
