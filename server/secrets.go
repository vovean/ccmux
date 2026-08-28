package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// SecretStore is where credentials live. Keys are account IDs; values are opaque strings
// — a credential's JSON or a bare API key — because the store must never need to
// understand what it is holding.
type SecretStore interface {
	Read(key string) (string, bool, error)
	Write(key, value string) error
	Delete(key string) error
	Keys() ([]string, error)
}

// EncryptedFileStore is one AES-GCM sealed file, keyed by a 32-byte master key kept
// beside it at 0600.
//
// The encryption buys less than it looks like — anything that can read the sealed file
// can almost always read the key next to it. What it does buy is that a stray backup or a
// copied volume does not hand over live refresh tokens. The real boundary is filesystem
// permissions, which is why both files are 0600 in a 0700 directory.
type EncryptedFileStore struct {
	path string
	aead cipher.AEAD
	mu   sync.Mutex
}

// LoadOrCreateMasterKey generates the key on first run rather than asking the operator to
// handle key material.
func LoadOrCreateMasterKey(path string) ([]byte, error) {
	if data, err := os.ReadFile(path); err == nil {
		if len(data) != 32 {
			return nil, fmt.Errorf("master key at %s is not 32 bytes", path)
		}
		return data, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, key, 0o600); err != nil {
		return nil, err
	}
	return key, nil
}

func NewEncryptedFileStore(path string, key []byte) (*EncryptedFileStore, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &EncryptedFileStore{path: path, aead: aead}, nil
}

func (s *EncryptedFileStore) Read(key string) (string, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return "", false, err
	}
	value, ok := all[key]
	return value, ok, nil
}

func (s *EncryptedFileStore) Write(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return err
	}
	all[key] = value
	return s.save(all)
}

func (s *EncryptedFileStore) Delete(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return err
	}
	if _, ok := all[key]; !ok {
		return nil
	}
	delete(all, key)
	return s.save(all)
}

func (s *EncryptedFileStore) Keys() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(all))
	for key := range all {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys, nil
}

func (s *EncryptedFileStore) load() (map[string]string, error) {
	sealed, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && len(sealed) == 0) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	size := s.aead.NonceSize()
	if len(sealed) < size {
		return nil, fmt.Errorf("could not open %s — file is truncated",
			filepath.Base(s.path))
	}
	plaintext, err := s.aead.Open(nil, sealed[:size], sealed[size:], nil)
	if err != nil {
		// Refusing loudly is the only safe move: carrying on with an empty map would
		// silently overwrite every live refresh token on the next write.
		return nil, fmt.Errorf("could not open %s — wrong master key?",
			filepath.Base(s.path))
	}
	var all map[string]string
	if err := json.Unmarshal(plaintext, &all); err != nil {
		return nil, err
	}
	if all == nil {
		all = map[string]string{}
	}
	return all, nil
}

func (s *EncryptedFileStore) save(all map[string]string) error {
	plaintext, err := json.Marshal(all)
	if err != nil {
		return err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	sealed := s.aead.Seal(nonce, nonce, plaintext, nil)
	// Written to a temp then renamed: a truncated write here loses every credential the
	// server holds. rename(2) within a directory is atomic.
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, sealed, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// PrefixedStore is a namespaced view onto another store, so OAuth credentials and API
// keys can share one sealed file without an account id in both ever colliding. They
// authenticate with different headers entirely, and confusing the two shapes is the
// failure worth ruling out structurally.
type PrefixedStore struct {
	base   SecretStore
	prefix string
}

func NewPrefixedStore(base SecretStore, prefix string) *PrefixedStore {
	return &PrefixedStore{base: base, prefix: prefix}
}

func (p *PrefixedStore) Read(key string) (string, bool, error) {
	return p.base.Read(p.prefix + key)
}

func (p *PrefixedStore) Write(key, value string) error {
	return p.base.Write(p.prefix+key, value)
}

func (p *PrefixedStore) Delete(key string) error { return p.base.Delete(p.prefix + key) }

func (p *PrefixedStore) Keys() ([]string, error) {
	all, err := p.base.Keys()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, key := range all {
		if len(key) > len(p.prefix) && key[:len(p.prefix)] == p.prefix {
			out = append(out, key[len(p.prefix):])
		}
	}
	return out, nil
}

// MemoryStore outlives nothing. For tests.
type MemoryStore struct {
	mu    sync.Mutex
	items map[string]string
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{items: map[string]string{}}
}

func (m *MemoryStore) Read(key string) (string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	value, ok := m.items[key]
	return value, ok, nil
}

func (m *MemoryStore) Write(key, value string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items[key] = value
	return nil
}

func (m *MemoryStore) Delete(key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.items, key)
	return nil
}

func (m *MemoryStore) Keys() ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	keys := make([]string, 0, len(m.items))
	for key := range m.items {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys, nil
}

// readFileString is a small helper used by tests that assert on sealed-file contents.
func readFileString(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
