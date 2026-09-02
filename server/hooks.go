package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"strings"
	"sync"
	"time"
)

// The hook scripts every Mac should be running, held centrally so three laptops do not
// drift.
//
// This is a code-distribution channel: whatever lands here is written to disk on each Mac
// and executed by Claude Code. The credential guarding it already hands out live OAuth
// tokens, so it is not a new trust boundary — but a bug here would be executed rather than
// merely read, so the shape is validated on the way in as well as on the way out, and the
// client re-checks every path before writing. Nothing is ever executed on the server.
type HookStore struct {
	mu     sync.Mutex
	bundle HookBundle
	path   string
	// Set when a stored bundle exists but could not be read. Distinct from "no bundle":
	// serving an empty set in that case tells every Mac to delete the hooks it has, so a
	// transient read error or a rollback to a stricter binary would wipe the fleet.
	unreadable error
}

const (
	// A hook is a short script. These bound what one PUT can pin to disk on three
	// machines, and sit well inside decodeBody's 1 MiB request cap.
	maxHookFiles     = 64
	maxHookFileBytes = 64 << 10
	maxHookTotal     = 256 << 10
	maxHookPathRunes = 128
	maxHookDepth     = 4
)

func NewHookStore(path string) *HookStore {
	store := &HookStore{path: path,
		bundle: HookBundle{APIVersion: apiVersion, Version: emptyBundleVersion}}
	if path != "" {
		// The registry does the same after its own temp-and-rename; without it a crash
		// between the write and the rename leaves a temp in the data directory forever.
		sweepStaleTempFiles(path)
	}
	store.load()
	return store
}

// The version of a bundle with no files, so a client that has applied nothing and a
// server holding nothing agree without a special case.
var emptyBundleVersion = hookVersion(nil)

// Get reports the bundle, or the reason it cannot be trusted. A caller must not treat an
// error as an empty set.
func (s *HookStore) Get() (HookBundle, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.unreadable != nil {
		return HookBundle{}, s.unreadable
	}
	out := s.bundle
	out.Files = copyHookFiles(s.bundle.Files)
	return out, nil
}

// Never nil: encoding/json writes a nil slice as null, and the Mac client refuses a
// bundle whose files are absent rather than read it as "delete everything". An empty set
// has to arrive as [], or a ccmuxd that has never published a hook wedges every client.
func copyHookFiles(files []HookFile) []HookFile {
	out := make([]HookFile, len(files))
	copy(out, files)
	return out
}

// Replace validates and stores a whole bundle. Whole rather than incremental: a hook set
// is only meaningful complete, and a partial update is how one Mac ends up running half
// of one revision and half of another.
func (s *HookStore) Replace(files []HookFile, now time.Time) (HookBundle, error) {
	cleaned, err := validateHookFiles(files)
	if err != nil {
		return HookBundle{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.bundle = HookBundle{
		APIVersion: apiVersion,
		Version:    hookVersion(cleaned),
		UpdatedAt:  Time{now.UTC()},
		Files:      cleaned,
	}
	// A successful publish supersedes whatever could not be read before.
	s.unreadable = nil
	s.persistLocked()
	out := s.bundle
	out.Files = copyHookFiles(s.bundle.Files)
	return out, nil
}

// SetActive flips one script's registration flag and returns the whole bundle.
//
// Under the store's own lock, so two Macs toggling different scripts cannot lose each
// other's change the way a read-modify-write of the whole bundle would.
func (s *HookStore) SetActive(path string, active bool, now time.Time) (HookBundle, error) {
	clean, err := validateHookPath(path)
	if err != nil {
		return HookBundle{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.unreadable != nil {
		return HookBundle{}, s.unreadable
	}
	found := false
	for i := range s.bundle.Files {
		if s.bundle.Files[i].Path != clean {
			continue
		}
		found = true
		if s.bundle.Files[i].IsActive() == active {
			break
		}
		flag := active
		s.bundle.Files[i].Active = &flag
		s.bundle.UpdatedAt = Time{now.UTC()}
		s.persistLocked()
		break
	}
	if !found {
		return HookBundle{}, fmt.Errorf("no such hook: %s", clean)
	}
	out := s.bundle
	out.Files = copyHookFiles(s.bundle.Files)
	return out, nil
}

// validateHookFiles is the gate. Every rule here exists because the result is written to
// a path on someone else's disk and then run.
func validateHookFiles(files []HookFile) ([]HookFile, error) {
	if len(files) > maxHookFiles {
		return nil, fmt.Errorf("too many files: %d (max %d)", len(files), maxHookFiles)
	}
	total := 0
	seen := map[string]bool{}
	// Keyed case-insensitively: the Macs run on APFS, which is case-insensitive by
	// default, so a.sh and A.sh are two published files that collapse to one on disk. The
	// version could then never converge, and the client would write and delete forever.
	folded := map[string]string{}
	dirs := map[string]bool{}
	out := make([]HookFile, 0, len(files))
	for _, file := range files {
		clean, err := validateHookPath(file.Path)
		if err != nil {
			return nil, err
		}
		if seen[clean] {
			return nil, fmt.Errorf("duplicate path: %s", clean)
		}
		lower := strings.ToLower(clean)
		if other, ok := folded[lower]; ok {
			return nil, fmt.Errorf("%s and %s differ only by case", other, clean)
		}
		folded[lower] = clean
		seen[clean] = true
		for dir := path.Dir(clean); dir != "." && dir != "/"; dir = path.Dir(dir) {
			dirs[strings.ToLower(dir)] = true
		}
		if len(file.Content) > maxHookFileBytes {
			return nil, fmt.Errorf("%s is %d bytes (max %d)", clean, len(file.Content), maxHookFileBytes)
		}
		total += len(file.Content)
		if total > maxHookTotal {
			return nil, fmt.Errorf("bundle exceeds %d bytes", maxHookTotal)
		}
		out = append(out, HookFile{Path: clean, Content: file.Content,
			Executable: file.Executable, Active: file.Active})
	}
	// A path that is both a file and a parent directory cannot exist. Accepting the pair
	// wedges every Mac: one of the two writes fails, the prune never runs, and the version
	// never converges — with no way back except deleting the path by hand on each machine.
	for _, file := range out {
		if dirs[strings.ToLower(file.Path)] {
			return nil, fmt.Errorf("%s is also a directory in this bundle", file.Path)
		}
	}
	sortHookFiles(out)
	return out, nil
}

// A path has to land inside the managed directory and nowhere else. Rejected rather than
// sanitised: silently rewriting a path that tried to escape would hide the attempt, and a
// hook whose name is not what its author wrote is worse than a refused push.
func validateHookPath(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("empty path")
	}
	if len([]rune(raw)) > maxHookPathRunes {
		return "", fmt.Errorf("path too long: %q", raw)
	}
	if strings.ContainsAny(raw, "\\\x00") {
		return "", fmt.Errorf("illegal character in path: %q", raw)
	}
	if strings.HasPrefix(raw, "/") {
		return "", fmt.Errorf("path must be relative: %q", raw)
	}
	clean := path.Clean(raw)
	if clean != raw {
		return "", fmt.Errorf("path must already be clean: %q", raw)
	}
	if clean == "." || strings.HasPrefix(clean, "../") || clean == ".." {
		return "", fmt.Errorf("path escapes the managed directory: %q", raw)
	}
	segments := strings.Split(clean, "/")
	if len(segments) > maxHookDepth {
		return "", fmt.Errorf("path is nested too deeply: %q", raw)
	}
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." {
			return "", fmt.Errorf("illegal path segment in %q", raw)
		}
		// A leading dot would hide the file from the client's own listing, which is how
		// something outlives a prune it should not have.
		if strings.HasPrefix(segment, ".") {
			return "", fmt.Errorf("path segment may not start with a dot: %q", raw)
		}
		// ASCII only, and a deliberately narrow slice of it. Go orders paths by byte and
		// Swift orders them by Unicode collation, so a non-ASCII name makes the two sides
		// hash the same bundle differently and the client rewrites it every minute
		// forever. Restricting the alphabet removes that divergence rather than trying to
		// match two collation orders, and takes NFC-versus-NFD with it.
		for _, r := range segment {
			if !isHookPathRune(r) {
				return "", fmt.Errorf("path may only use letters, digits, dot, dash and "+
					"underscore: %q", raw)
			}
		}
	}
	return clean, nil
}

func isHookPathRune(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		return true
	case r == '.' || r == '-' || r == '_':
		return true
	}
	return false
}

// A content hash, so a client can skip a bundle it already has without the server
// tracking who has what. Length-prefixed: without it "ab"+"c" and "a"+"bc" hash alike.
func hookVersion(files []HookFile) string {
	sum := sha256.New()
	for _, file := range files {
		fmt.Fprintf(sum, "%d:%s\n%d:%s\n%t\n", len(file.Path), file.Path,
			len(file.Content), file.Content, file.Executable)
	}
	return hex.EncodeToString(sum.Sum(nil))
}

func sortHookFiles(files []HookFile) {
	for i := 1; i < len(files); i++ {
		for j := i; j > 0 && files[j].Path < files[j-1].Path; j-- {
			files[j], files[j-1] = files[j-1], files[j]
		}
	}
}

func (s *HookStore) load() {
	if s.path == "" {
		return
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		// Nothing published yet is the normal fresh state; anything else means a set may
		// exist that we cannot see, and serving "empty" would delete it everywhere.
		if !os.IsNotExist(err) {
			s.unreadable = fmt.Errorf("could not read %s: %w", s.path, err)
			logError("%v", s.unreadable)
		}
		return
	}
	var bundle HookBundle
	if err := json.Unmarshal(raw, &bundle); err != nil {
		s.unreadable = fmt.Errorf("could not parse %s: %w", s.path, err)
		logError("%v", s.unreadable)
		return
	}
	// Re-validated on load: the file is ours, but a hand-edit or a partial write must not
	// become something the clients then execute.
	cleaned, err := validateHookFiles(bundle.Files)
	if err != nil {
		s.unreadable = fmt.Errorf("stored hooks are not valid: %w", err)
		logError("%v", s.unreadable)
		return
	}
	bundle.Files = cleaned
	bundle.APIVersion = apiVersion
	bundle.Version = hookVersion(cleaned)
	s.bundle = bundle
}

func (s *HookStore) persistLocked() {
	if s.path == "" {
		return
	}
	encoded, err := json.MarshalIndent(s.bundle, "", "  ")
	if err != nil {
		logError("could not encode hooks: %v", err)
		return
	}
	tmp := fmt.Sprintf("%s.%d.%d.tmp", s.path, os.Getpid(), atomicNextTemp())
	if err := os.WriteFile(tmp, encoded, 0o600); err != nil {
		os.Remove(tmp)
		logError("could not write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		logError("could not save %s: %v", s.path, err)
	}
}
