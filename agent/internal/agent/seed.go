package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ccmuxd/wire"
)

// The file Claude Code reads its credential from when CLAUDE_SECURESTORAGE_CONFIG_DIR is
// set. Verified against Claude Code 2.1.272 on Linux: it reads this path, authenticates
// as the token inside, and adds the OAuth beta header itself.
const credentialFile = ".credentials.json"

// PlaceholderToken authenticates nothing. A session running on an API-key account still
// needs a credential in its namespace, because Claude Code checks for one at startup and
// refuses to run without it; the proxy replaces the header with x-api-key on every
// request. Deliberately not a real-looking secret, and with no refresh token, so nothing
// here can rotate a lineage.
const PlaceholderToken = "ccmux-api-key-session"

// Grant is one account's short-lived credential, as ccmuxd handed it over.
type Grant struct {
	AccountID        string
	Kind             wire.AccountKind
	AccessToken      string
	APIKey           string
	ExpiresAt        time.Time
	SubscriptionType string
	RateLimitTier    string
	Scopes           []string
}

// seedKey is what a namespace written from this grant holds that Claude Code reads: a plan
// can arrive later under the same token, and that has to be written too.
func (g Grant) seedKey() string {
	return strings.Join([]string{g.AccessToken, g.SubscriptionType, g.RateLimitTier,
		strings.Join(g.Scopes, " ")}, "\x00")
}

func grantFromWire(g wire.TokenGrant, now time.Time) Grant {
	grant := Grant{AccountID: g.AccountID, Kind: g.Kind, Scopes: g.Scopes}
	if g.AccessToken != nil {
		grant.AccessToken = *g.AccessToken
	}
	if g.APIKey != nil {
		grant.APIKey = *g.APIKey
	}
	// Seconds, not an absolute date: the server and this box do not agree on the wall
	// clock, and trusting a remote timestamp would treat dead tokens as fresh.
	if g.ExpiresIn != nil {
		grant.ExpiresAt = now.Add(time.Duration(*g.ExpiresIn * float64(time.Second)))
	}
	if g.SubscriptionType != nil {
		grant.SubscriptionType = *g.SubscriptionType
	}
	if g.RateLimitTier != nil {
		grant.RateLimitTier = *g.RateLimitTier
	}
	return grant
}

func (g Grant) usable(now time.Time) bool {
	if g.Kind == wire.KindAPIKey {
		return g.APIKey != ""
	}
	return g.AccessToken != "" && (g.ExpiresAt.IsZero() || g.ExpiresAt.After(now))
}

// seededCredential is the JSON Claude Code expects, field for field as the Mac writes it.
//
// A plan that is missing reads as unentitled, so subscriptionType and rateLimitTier are
// carried through when the server knows them. There is never a refresh token: ccmuxd is
// the sole holder of every lineage, and a box that could refresh could rotate one behind
// the server's back.
func seededCredential(grant Grant, now time.Time) ([]byte, error) {
	oauth := map[string]any{}
	if grant.Kind == wire.KindAPIKey {
		oauth["accessToken"] = PlaceholderToken
		oauth["expiresAt"] = now.Add(365 * 24 * time.Hour).UnixMilli()
		oauth["scopes"] = []string{"user:inference", "user:profile"}
	} else {
		oauth["accessToken"] = grant.AccessToken
		if !grant.ExpiresAt.IsZero() {
			oauth["expiresAt"] = grant.ExpiresAt.UnixMilli()
		}
		if len(grant.Scopes) > 0 {
			oauth["scopes"] = grant.Scopes
		}
		if grant.SubscriptionType != "" {
			oauth["subscriptionType"] = grant.SubscriptionType
		}
		if grant.RateLimitTier != "" {
			oauth["rateLimitTier"] = grant.RateLimitTier
		}
	}
	return json.Marshal(map[string]any{"claudeAiOauth": oauth})
}

// Seed writes the credential a session's Claude Code will authenticate as.
//
// Rewritten in place whenever the token is renewed: Claude Code watches this file's
// modification time and re-reads it, so a run outliving its access token keeps going.
func Seed(namespace string, grant Grant, now time.Time) error {
	if err := os.MkdirAll(namespace, 0o700); err != nil {
		return err
	}
	// MkdirAll honours the umask, so the modes have to be set outright — these
	// directories hold live access tokens. The parent too: MkdirAll created it, and a
	// hand-set state_dir is not covered by systemd's StateDirectoryMode.
	for _, dir := range []string{filepath.Dir(namespace), namespace} {
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	data, err := seededCredential(grant, now)
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(namespace, credentialFile), data, 0o600)
}

// Clear removes a finished session's namespace, and with it the token inside.
func Clear(namespace string) error {
	if err := os.RemoveAll(namespace); err != nil {
		return fmt.Errorf("could not remove %s: %w", namespace, err)
	}
	return nil
}
