package ledger

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ccmuxd/wire"
)

var noon = time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)

func identity(session, account, model string) Identity {
	return Identity{SessionID: session, SessionName: session + "-name", AccountID: account,
		AccountLabel: "Label " + account, Kind: wire.KindSubscription, Model: model}
}

func TestRequestsInOneMinuteFoldIntoOneBucket(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 10, Output: 5}, identity("s1", "a1", "claude-opus-5"), noon)
	l.Record(TokenUsage{Input: 3, Output: 2}, identity("s1", "a1", "claude-opus-5"),
		noon.Add(30*time.Second))
	l.CloseElapsed(noon.Add(time.Minute))

	batch := l.Batch()
	if len(batch) != 1 {
		t.Fatalf("got %d buckets", len(batch))
	}
	if batch[0].Requests != 2 || batch[0].Input != 13 || batch[0].Output != 7 {
		t.Errorf("got %+v", batch[0])
	}
	if !batch[0].Minute.Equal(noon) {
		t.Errorf("minute %v", batch[0].Minute)
	}
}

// ccmux moves a session to another account when one refuses, and that happens mid-minute
// on the same model. Without the account in the key the whole minute would be booked to
// whichever account served last.
func TestAMoveMidMinuteSplitsTheBucket(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 10}, identity("s1", "a1", "claude-opus-5"), noon)
	l.Record(TokenUsage{Input: 4}, identity("s1", "a2", "claude-opus-5"), noon.Add(20*time.Second))
	l.CloseElapsed(noon.Add(time.Minute))

	batch := l.Batch()
	if len(batch) != 2 {
		t.Fatalf("got %d buckets, want one per account", len(batch))
	}
	byAccount := map[string]int{}
	for _, bucket := range batch {
		byAccount[bucket.AccountID] = bucket.Input
	}
	if byAccount["a1"] != 10 || byAccount["a2"] != 4 {
		t.Errorf("got %v", byAccount)
	}
}

// The immutability the whole retry story rests on: a minute still running is never sent.
func TestAnOpenMinuteIsNeverHandedOver(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 1}, identity("s1", "a1", "claude-opus-5"), noon.Add(10*time.Second))
	if n := l.CloseElapsed(noon.Add(40 * time.Second)); n != 0 {
		t.Fatalf("closed %d minutes that had not ended", n)
	}
	if len(l.Batch()) != 0 {
		t.Fatal("an open minute reached the batch")
	}
	if n := l.CloseElapsed(noon.Add(time.Minute)); n != 1 {
		t.Fatalf("closed %d", n)
	}
}

// A push over a slow link outlives a tick, and the queue is trimmed from the front when
// it hits its ceiling, so acknowledging by count would delete buckets that were never
// sent.
func TestAcknowledgeRemovesExactlyWhatWasSent(t *testing.T) {
	l := New()
	for i := 0; i < 3; i++ {
		l.Record(TokenUsage{Input: 1}, identity("s1", "a1", "claude-opus-5"),
			noon.Add(time.Duration(i)*time.Minute))
	}
	l.CloseElapsed(noon.Add(3 * time.Minute))
	batch := l.Batch()
	if len(batch) != 3 {
		t.Fatalf("got %d", len(batch))
	}
	l.Acknowledge(batch[:2])
	rest := l.Batch()
	if len(rest) != 1 || !rest[0].Minute.Equal(noon.Add(2*time.Minute)) {
		t.Fatalf("got %+v", rest)
	}
	// A re-send of something already gone must not remove anything else.
	l.Acknowledge(batch[:2])
	if l.Pending() != 1 {
		t.Errorf("pending %d", l.Pending())
	}
}

func TestTheQueueIsBoundedAndDropsTheOldestFirst(t *testing.T) {
	l := New()
	for i := 0; i < MaxPending+5; i++ {
		l.Record(TokenUsage{Input: 1}, identity("s1", "a1", "claude-opus-5"),
			noon.Add(time.Duration(i)*time.Minute))
	}
	l.CloseElapsed(noon.Add(time.Duration(MaxPending+10) * time.Minute))
	if l.Pending() != MaxPending {
		t.Fatalf("pending %d", l.Pending())
	}
	// The five dropped are the five oldest.
	if first := l.Batch()[0]; !first.Minute.Equal(noon.Add(5 * time.Minute)) {
		t.Errorf("oldest kept is %v", first.Minute)
	}
}

// The server caps a request body at 1 MiB, and the fields in a bucket are user-supplied,
// so the only honest bound is the measured length.
func TestABatchIsBoundedByItsEncodedSize(t *testing.T) {
	l := New()
	long := strings.Repeat("n", MaxFieldBytes)
	for i := 0; i < 400; i++ {
		id := identity("s1", "a1", "claude-opus-5")
		id.SessionName = long
		id.AccountLabel = long
		l.Record(TokenUsage{Input: 1}, id, noon.Add(time.Duration(i)*time.Minute))
	}
	l.CloseElapsed(noon.Add(500 * time.Minute))
	batch := l.Batch()
	if size := encodedSize(batch); size > MaxPushBytes {
		t.Fatalf("batch encodes to %d bytes", size)
	}
	if len(batch) == 0 {
		t.Fatal("the batch was emptied rather than trimmed")
	}
}

// Refusing to send an over-large bucket would wedge the queue behind it forever.
func TestOneOversizedBucketStillGoes(t *testing.T) {
	kept := fit([]wire.UsageBucket{{SessionID: strings.Repeat("x", 4096)}}, 16)
	if len(kept) != 1 {
		t.Fatalf("got %d", len(kept))
	}
}

func TestFieldsAreClampedOnAByteBoundary(t *testing.T) {
	// Cyrillic is two bytes a character, so 256 bytes is 128 characters.
	long := strings.Repeat("я", 200)
	got := clamp(long)
	if len(got) > MaxFieldBytes {
		t.Fatalf("clamped to %d bytes", len(got))
	}
	if !json.Valid([]byte(`"` + got + `"`)) {
		t.Fatal("clamping split a character")
	}
}

// A restart mid-minute has to resume the same bucket, not start a second one that would
// replace it on the server.
func TestAnOpenMinuteSurvivesARestartStillOpen(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 7}, identity("s1", "a1", "claude-opus-5"), noon)
	spool, dirty := l.TakeSpool()
	if !dirty {
		t.Fatal("a recorded request did not mark the spool dirty")
	}
	if len(spool.Open) != 1 || len(spool.Pending) != 0 {
		t.Fatalf("got %+v", spool)
	}

	revived := New()
	revived.Restore(spool)
	revived.Record(TokenUsage{Input: 3}, identity("s1", "a1", "claude-opus-5"),
		noon.Add(20*time.Second))
	revived.CloseElapsed(noon.Add(time.Minute))
	batch := revived.Batch()
	if len(batch) != 1 || batch[0].Input != 10 || batch[0].Requests != 2 {
		t.Fatalf("the restart started a second bucket: %+v", batch)
	}
}

func TestATickThatChangedNothingDoesNotRewriteTheSpool(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 1}, identity("s1", "a1", "claude-opus-5"), noon)
	if _, dirty := l.TakeSpool(); !dirty {
		t.Fatal("first take should be dirty")
	}
	if _, dirty := l.TakeSpool(); dirty {
		t.Error("a second take with no change should not rewrite the file")
	}
}

func TestLoadSpoolOfAMissingFileIsEmpty(t *testing.T) {
	spool, err := LoadSpool(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(spool.Open) != 0 || len(spool.Pending) != 0 {
		t.Errorf("got %+v", spool)
	}
}

func TestAnUnknownModelIsRecordedAsUnpriced(t *testing.T) {
	l := New()
	l.Record(TokenUsage{Input: 1000}, identity("s1", "a1", "claude-unheard-of-9"), noon)
	l.CloseElapsed(noon.Add(time.Minute))
	if cost := l.Batch()[0].CostUSD; cost != nil {
		t.Errorf("guessed a price for an unknown model: %v", *cost)
	}
}

func TestASpoolRoundTripsThroughDisk(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage-spool.json")
	l := New()
	l.Record(TokenUsage{Input: 5, Output: 2}, identity("s1", "a1", "claude-opus-5"), noon)
	l.CloseElapsed(noon.Add(time.Minute))
	spool, _ := l.TakeSpool()
	data, err := json.Marshal(spool)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	back, err := LoadSpool(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(back.Pending) != 1 || back.Pending[0].Input != 5 {
		t.Fatalf("got %+v", back)
	}
	if !back.Pending[0].Minute.Equal(noon) {
		t.Errorf("minute did not survive: %v", back.Pending[0].Minute)
	}
}
