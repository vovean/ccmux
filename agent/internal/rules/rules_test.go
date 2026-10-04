package rules

import (
	"testing"
	"time"

	"ccmuxd/wire"
)

// The Mac breaks a headroom tie on an account priority that is local to each machine and
// never crosses the wire, so the agent cannot reproduce it. What it can do is be
// deterministic, so two Linux boxes reading the same answer drain the same subscription
// first. The cross-language vectors deliberately contain no tie; this pins what happens
// in one.
func TestATieIsBrokenOnTheLabelThenTheID(t *testing.T) {
	fresh := func(id, label string) wire.RemoteAccount {
		return wire.RemoteAccount{ID: id, Label: label, Kind: wire.KindSubscription,
			Health: wire.HealthOK}
	}
	usage := map[string]*Snapshot{}
	for _, id := range []string{"z", "m", "a"} {
		usage[id] = &Snapshot{Windows: []wire.UsageWindow{
			{Kind: wire.WindowWeeklyAll, Label: "Weekly", Percent: 20}}}
	}
	accounts := []wire.RemoteAccount{fresh("z", "Beta"), fresh("m", "alpha"), fresh("a", "Beta")}
	ranked := RankLeastRemaining("claude-opus-5", accounts, usage, nil)
	got := []string{ranked[0].ID, ranked[1].ID, ranked[2].ID}
	// "alpha" sorts before "Beta" case-insensitively; the two Betas split on id.
	want := []string{"m", "a", "z"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

// An account with no label at all falls back to its id, which is what DisplayName does.
func TestAnUnlabelledAccountStillOrdersDeterministically(t *testing.T) {
	accounts := []wire.RemoteAccount{
		{ID: "bbb", Kind: wire.KindSubscription, Health: wire.HealthOK},
		{ID: "aaa", Kind: wire.KindSubscription, Health: wire.HealthOK},
	}
	ranked := RankLeastRemaining("claude-opus-5", accounts, nil, nil)
	if ranked[0].ID != "aaa" || ranked[1].ID != "bbb" {
		t.Fatalf("got %s then %s", ranked[0].ID, ranked[1].ID)
	}
}

// A window whose display name is two non-ASCII characters is several bytes long, and
// counting bytes would let it gate requests here while the Mac ignores it.
func TestTheScopeGuardCountsCharactersNotBytes(t *testing.T) {
	short := wire.UsageWindow{Kind: wire.WindowWeeklyScoped, ModelName: wire.Ptr("Фи")}
	if Governs(short, "claude-фи-5") {
		t.Error("a two-character name should govern nothing")
	}
	long := wire.UsageWindow{Kind: wire.WindowWeeklyScoped, ModelName: wire.Ptr("Фабл")}
	if !Governs(long, "claude-фабл-5") {
		t.Error("a four-character name should match its model")
	}
}

// Truncating a fractional epoch moves the moment by up to a second, which flips the
// comparison that decides whether the upstream reset is already sooner than ours.
func TestAFractionalResetKeepsItsFraction(t *testing.T) {
	to := time.Unix(1789480800, 0).UTC()
	headers := []Header{{resetHeader, "1789480800.5"}}
	if _, changed := ShorteningReset(headers, to, to.Add(-time.Hour)); !changed {
		t.Error("an upstream reset half a second later than ours should be shortened")
	}
	// And one genuinely earlier is still left alone.
	if _, changed := ShorteningReset([]Header{{resetHeader, "1789480799.5"}}, to,
		to.Add(-time.Hour)); changed {
		t.Error("a sooner upstream reset was lengthened")
	}
}

func TestAnUnreadableResetHeaderIsIgnoredRatherThanTrusted(t *testing.T) {
	to := time.Unix(1789480800, 0).UTC()
	for _, raw := range []string{"not-a-number", "1e400", "99999999999999999999", ""} {
		out, changed := ShorteningReset([]Header{{resetHeader, raw}}, to, to.Add(-time.Hour))
		if !changed {
			t.Errorf("%q: an unreadable reset should not stop us naming a real one", raw)
			continue
		}
		if last := out[len(out)-1]; last.Value != "1789480800" {
			t.Errorf("%q: wrote %q", raw, last.Value)
		}
	}
}

func TestOrganizationRefusesOAuth(t *testing.T) {
	refusal := []byte(`{"type":"error","error":{"type":"permission_error","message":` +
		`"OAuth authentication is currently not allowed for this organization.",` +
		`"details":{"error_code":"oauth_not_allowed_for_organization"}}}`)
	if !OrganizationRefusesOAuth(refusal) {
		t.Error("the refusal was not recognised")
	}
	if OrganizationRefusesOAuth([]byte(`{"error":{"type":"permission_error"}}`)) {
		t.Error("another permission error was taken for the refusal")
	}
}
