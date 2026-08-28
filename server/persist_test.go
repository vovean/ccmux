package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// accounts.json must never be observed half-written.
//
// The Swift original wrote through a UUID-unique temp path with the comment "two
// concurrent saves of the same file would otherwise race on one temp path and lose a
// write"; the port dropped it and used a single fixed `.tmp`. Two goroutines then open
// the same file with O_TRUNC and interleave.
//
// The damage is not at write time. A corrupt accounts.json parses as nothing on the next
// restart, the registry boots with zero accounts, every token request 404s, and the
// client maps a 404 to a *permanent* failure — so every delegated account on every Mac is
// flagged as needing a browser sign-in, and the next persist writes `[]` over the wreck.
func TestConcurrentPersistNeverCorruptsTheAccountsFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "accounts.json")

	big := make([]RemoteAccount, 0, 40)
	for i := 0; i < 40; i++ {
		big = append(big, RemoteAccount{
			ID:    string(rune('a'+i%26)) + "-a-fairly-long-account-identifier",
			Label: "An account with a reasonably long label to make the payloads differ",
			Kind:  KindSubscription, Health: HealthOK,
		})
	}
	small := []RemoteAccount{{ID: "one", Label: "One", Kind: KindAPIKey, Health: HealthOK}}

	for round := 0; round < 300; round++ {
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); saveAccountsFile(path, big) }()
		go func() { defer wg.Done(); saveAccountsFile(path, small) }()
		wg.Wait()

		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("round %d: %v", round, err)
		}
		var parsed []RemoteAccount
		if err := json.Unmarshal(raw, &parsed); err != nil {
			t.Fatalf("round %d: accounts.json is unparseable after concurrent saves: %v\n%s",
				round, err, raw)
		}
		if len(parsed) != len(big) && len(parsed) != len(small) {
			t.Fatalf("round %d: file holds a spliced list of %d accounts", round, len(parsed))
		}
	}
}
