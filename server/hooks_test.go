package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAHookPathMayNotEscapeTheManagedDirectory(t *testing.T) {
	// Every one of these is written to a path on someone else's disk and then executed,
	// so each is refused rather than sanitised.
	for _, bad := range []string{
		"../evil.sh", "..", "/etc/cron.d/evil", "a/../../evil.sh", "a//b.sh",
		"./a.sh", "a/./b.sh", "back\\slash.sh", "with\x00null", "",
		".hidden.sh", "dir/.hidden", "a/b/c/d/e.sh",
	} {
		if _, err := validateHookPath(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	for _, good := range []string{"a.sh", "UserPromptSubmit/fable.sh", "a/b/c.sh"} {
		if _, err := validateHookPath(good); err != nil {
			t.Errorf("rejected %q: %v", good, err)
		}
	}
}

func TestABundleIsBoundedInCountAndSize(t *testing.T) {
	many := make([]HookFile, maxHookFiles+1)
	for i := range many {
		many[i] = HookFile{Path: "f" + string(rune('a'+i%26)) + itoa(i) + ".sh", Content: "x"}
	}
	if _, err := validateHookFiles(many); err == nil {
		t.Fatal("accepted too many files")
	}
	big := []HookFile{{Path: "big.sh", Content: strings.Repeat("x", maxHookFileBytes+1)}}
	if _, err := validateHookFiles(big); err == nil {
		t.Fatal("accepted an oversized file")
	}
	// Individually legal, collectively not.
	var total []HookFile
	for i := 0; i*maxHookFileBytes <= maxHookTotal; i++ {
		total = append(total, HookFile{Path: "f" + itoa(i) + ".sh",
			Content: strings.Repeat("x", maxHookFileBytes)})
	}
	if _, err := validateHookFiles(total); err == nil {
		t.Fatal("accepted a bundle over the total cap")
	}
}

func TestDuplicatePathsAreRefused(t *testing.T) {
	_, err := validateHookFiles([]HookFile{{Path: "a.sh", Content: "1"}, {Path: "a.sh", Content: "2"}})
	if err == nil {
		t.Fatal("accepted two files at one path")
	}
}

// The version is the client's only signal that it has work to do, so it must depend on
// content and nothing else.
func TestTheVersionIsContentAddressedAndOrderIndependent(t *testing.T) {
	a := []HookFile{{Path: "a.sh", Content: "one"}, {Path: "b.sh", Content: "two"}}
	b := []HookFile{{Path: "b.sh", Content: "two"}, {Path: "a.sh", Content: "one"}}
	ca, _ := validateHookFiles(a)
	cb, _ := validateHookFiles(b)
	if hookVersion(ca) != hookVersion(cb) {
		t.Fatal("order changed the version")
	}
	changed, _ := validateHookFiles([]HookFile{{Path: "a.sh", Content: "one"},
		{Path: "b.sh", Content: "three"}})
	if hookVersion(changed) == hookVersion(ca) {
		t.Fatal("a content change did not change the version")
	}
	// Length-prefixed, so a shifted boundary is not the same hash.
	x, _ := validateHookFiles([]HookFile{{Path: "a.sh", Content: "ab"}, {Path: "b.sh", Content: "c"}})
	y, _ := validateHookFiles([]HookFile{{Path: "a.sh", Content: "a"}, {Path: "b.sh", Content: "bc"}})
	if hookVersion(x) == hookVersion(y) {
		t.Fatal("boundary shift collided")
	}
	// Executability is part of the content: the same text at 0600 and 0700 are not the
	// same bundle, and a client that skipped one for the other would never run the hook.
	e1, _ := validateHookFiles([]HookFile{{Path: "a.sh", Content: "x", Executable: true}})
	e2, _ := validateHookFiles([]HookFile{{Path: "a.sh", Content: "x"}})
	if hookVersion(e1) == hookVersion(e2) {
		t.Fatal("the executable bit did not change the version")
	}
}

func TestAnEmptyBundleHasAStableVersion(t *testing.T) {
	store := NewHookStore("")
	got, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != emptyBundleVersion || len(got.Files) != 0 {
		t.Fatalf("a fresh store reports %+v", got)
	}
}

func TestABundleSurvivesARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hooks.json")
	first := NewHookStore(path)
	saved, err := first.Replace([]HookFile{{Path: "UserPromptSubmit/f.sh",
		Content: "#!/bin/sh\necho hi\n", Executable: true}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	again := NewHookStore(path)
	got, err := again.Get()
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != saved.Version || len(got.Files) != 1 {
		t.Fatalf("reload gave %+v", got)
	}
	if !got.Files[0].Executable {
		t.Fatal("the executable bit did not survive")
	}
}

// The stored file is ours, but a hand-edit must not become something three Macs execute.
func TestAStoredBundleIsRevalidatedOnLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hooks.json")
	tampered := HookBundle{APIVersion: apiVersion, Files: []HookFile{
		{Path: "../../../../etc/evil.sh", Content: "rm -rf /", Executable: true}}}
	raw, _ := json.Marshal(tampered)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	store := NewHookStore(path)
	// Refused, not served as empty: an empty answer tells every Mac to delete what it has.
	if _, err := store.Get(); err == nil {
		t.Fatal("an unreadable bundle was served as if it were empty")
	}
}

// The failure that would wipe the fleet: a stored set that cannot be read must never be
// answered as "there is no set", because the client deletes whatever the answer omits.
func TestAnUnreadableBundleIsRefusedRatherThanServedEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hooks.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := NewHookStore(path)
	if _, err := store.Get(); err == nil {
		t.Fatal("unparseable hooks.json was served as an empty bundle")
	}
	// A fresh publish supersedes it.
	if _, err := store.Replace([]HookFile{{Path: "a.sh", Content: "x"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Get(); err != nil {
		t.Fatalf("still refusing after a successful publish: %v", err)
	}
}

func TestAnUnreadableBundleAnswers503(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "hooks.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, _, client := startTestServerWithHooks(t, registry, NewHookStore(filepath.Join(dir, "hooks.json")))
	resp := authed(t, client, "GET", server.URL+"/v1/hooks", "")
	code := resp.StatusCode
	resp.Body.Close()
	if code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", code)
	}
}

// APFS is case-insensitive by default, so two paths differing only by case collapse to
// one file and the version can never converge.
func TestPathsThatDifferOnlyByCaseAreRefused(t *testing.T) {
	_, err := validateHookFiles([]HookFile{{Path: "a.sh", Content: "1"}, {Path: "A.sh", Content: "2"}})
	if err == nil {
		t.Fatal("accepted a.sh alongside A.sh")
	}
}

// One path cannot be both a file and a parent directory; accepting the pair wedges every
// Mac with no way back but deleting the path by hand.
func TestAPathMayNotBeBothFileAndDirectory(t *testing.T) {
	for _, pair := range [][]HookFile{
		{{Path: "tools", Content: "x"}, {Path: "tools/helper.sh", Content: "y"}},
		{{Path: "tools/helper.sh", Content: "y"}, {Path: "tools", Content: "x"}},
		{{Path: "a/b/c.sh", Content: "y"}, {Path: "a/b", Content: "x"}},
	} {
		if _, err := validateHookFiles(pair); err == nil {
			t.Fatalf("accepted %s alongside %s", pair[0].Path, pair[1].Path)
		}
	}
}

// Go orders paths by byte and Swift by Unicode collation; a non-ASCII name makes the two
// hash the same bundle differently and the client rewrites it every minute forever.
func TestNonASCIIPathsAreRefused(t *testing.T) {
	for _, bad := range []string{"á.sh", "e\u0301.sh", "naïve/x.sh", "emoji\U0001F600.sh",
		"with space.sh", "semi;colon.sh", "star*.sh"} {
		if _, err := validateHookPath(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestGetAndPutRoundTripOverHTTP(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())

	resp := authed(t, client, "GET", server.URL+"/v1/hooks", "")
	var empty HookBundle
	json.NewDecoder(resp.Body).Decode(&empty)
	resp.Body.Close()
	if len(empty.Files) != 0 || empty.APIVersion != apiVersion {
		t.Fatalf("fresh GET gave %+v", empty)
	}

	body := `{"files":[{"path":"UserPromptSubmit/fable.sh","content":"#!/bin/sh\n","executable":true}]}`
	put := authed(t, client, "PUT", server.URL+"/v1/hooks", body)
	var stored HookBundle
	json.NewDecoder(put.Body).Decode(&stored)
	code := put.StatusCode
	put.Body.Close()
	if code != http.StatusOK || len(stored.Files) != 1 {
		t.Fatalf("PUT gave %d %+v", code, stored)
	}

	after := authed(t, client, "GET", server.URL+"/v1/hooks", "")
	var got HookBundle
	json.NewDecoder(after.Body).Decode(&got)
	after.Body.Close()
	if got.Version != stored.Version {
		t.Fatalf("GET disagreed with PUT: %s vs %s", got.Version, stored.Version)
	}
}

func TestAPutWithATraversalPathIsRefused(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	server, _, client := startTestServerWith(t, registry, NewMachineStore())
	resp := authed(t, client, "PUT", server.URL+"/v1/hooks",
		`{"files":[{"path":"../../evil.sh","content":"x"}]}`)
	code := resp.StatusCode
	resp.Body.Close()
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", code)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var out []byte
	for n > 0 {
		out = append([]byte{byte('0' + n%10)}, out...)
		n /= 10
	}
	return string(out)
}

// The client decodes with Swift's `.iso8601`, which rejects fractional seconds. wire.go's
// Time wrapper exists for exactly this, and using a bare time.Time here made every push
// fail to decode on the Mac.
func TestTheBundleTimestampHasNoFractionalSeconds(t *testing.T) {
	store := NewHookStore("")
	saved, err := store.Replace([]HookFile{{Path: "a.sh", Content: "x"}},
		time.Date(2026, 9, 2, 10, 53, 5, 123456789, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(saved)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"updatedAt":"2026-09-02T10:53:05Z"`) {
		t.Fatalf("timestamp is not second-precision RFC3339: %s", raw)
	}
}

// A ccmuxd that has never published a hook must still answer with a files array. Go
// marshals a nil slice as null, and the Mac client refuses a bundle whose files are
// absent rather than read it as an instruction to delete every hook — so a fresh server
// used to wedge every client's sync with a decode error it could never get past.
func TestEmptyBundleMarshalsFilesAsAnArray(t *testing.T) {
	store := NewHookStore(filepath.Join(t.TempDir(), "hooks.json"))
	bundle, err := store.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	encoded, err := json.Marshal(bundle)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if !bytes.Contains(encoded, []byte(`"files":[]`)) {
		t.Fatalf("empty bundle did not carry an empty array: %s", encoded)
	}
	if bundle.Version == "" {
		t.Fatal("empty bundle carried no version")
	}

	// And the same after publishing an empty set deliberately.
	replaced, err := store.Replace(nil, time.Now())
	if err != nil {
		t.Fatalf("Replace: %v", err)
	}
	encoded, err = json.Marshal(replaced)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if !bytes.Contains(encoded, []byte(`"files":[]`)) {
		t.Fatalf("withdrawing every hook did not carry an empty array: %s", encoded)
	}
}
