package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func minuteAt(base time.Time, offset int) Time {
	return Time{base.Add(time.Duration(offset) * time.Minute).UTC().Truncate(time.Minute)}
}

func mustIngest(t *testing.T, store *SeriesStore, machineID string, report UsageReport,
	now time.Time) int {
	t.Helper()
	accepted, err := store.Ingest(machineID, report, now)
	if err != nil {
		t.Fatalf("ingest failed: %v", err)
	}
	return accepted
}

func sampleBucket(minute Time, sessionID, model string, input, output int) UsageBucket {
	return UsageBucket{
		Minute: minute, SessionID: sessionID, SessionName: "api-gateway",
		AccountID: "acct-1", AccountLabel: "Work", Kind: KindSubscription,
		Model: model, Requests: 1, Input: input, Output: output,
		CostUSD: ptr(0.5),
	}
}

func TestBucketsFoldOntoTheRangesGrid(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	// Two minutes inside one 5-minute slot, one in the next.
	report := UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -10), "sess-1", "claude-opus-5", 100, 10),
		sampleBucket(minuteAt(now, -9), "sess-1", "claude-opus-5", 200, 20),
		sampleBucket(minuteAt(now, -4), "sess-1", "claude-opus-5", 400, 40),
	}}
	if accepted := mustIngest(t, store, "mac-1", report, now); accepted != 3 {
		t.Fatalf("accepted %d, want 3", accepted)
	}

	stats, err := store.Stats("24h", now)
	if err != nil {
		t.Fatal(err)
	}
	if len(stats.Series) != 1 {
		t.Fatalf("got %d series, want 1", len(stats.Series))
	}
	series := stats.Series[0]
	if len(series.Points) != 2 {
		t.Fatalf("got %d points, want 2", len(series.Points))
	}
	if series.Points[0].Input != 300 || series.Points[1].Input != 400 {
		t.Errorf("points folded wrong: %d then %d", series.Points[0].Input,
			series.Points[1].Input)
	}
	if !series.Points[0].At.Before(series.Points[1].At.Time) {
		t.Error("points are not in time order")
	}
	if stats.Totals.Input != 700 || stats.Totals.Requests != 3 {
		t.Errorf("totals are %+v", stats.Totals)
	}
	if stats.BucketSeconds != 300 {
		t.Errorf("bucketSeconds is %d, want 300", stats.BucketSeconds)
	}
	if len(stats.Accounts) != 1 || stats.Accounts[0].Totals.Input != 700 {
		t.Errorf("account totals are %+v", stats.Accounts)
	}
}

// The property the whole design rests on: a Mac re-sends what it could not hand over, and
// only a minute that has ended is ever sent, so the newer copy is the same copy.
func TestResendingABucketDoesNotDoubleCount(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	report := UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -3), "sess-1", "claude-opus-5", 100, 10),
	}}
	mustIngest(t, store, "mac-1", report, now)
	mustIngest(t, store, "mac-1", report, now.Add(20*time.Second))

	stats, err := store.Stats("24h", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if stats.Totals.Input != 100 || stats.Totals.Requests != 1 {
		t.Fatalf("re-send was counted twice: %+v", stats.Totals)
	}
	if store.Count() != 1 {
		t.Errorf("holding %d buckets, want 1", store.Count())
	}
}

func TestAMinuteOutsideTheAcceptableWindowIsDropped(t *testing.T) {
	store := NewSeriesStore("", 48*time.Hour)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	report := UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(Time{now.Add(time.Hour)}, "future", "claude-opus-5", 1, 1),
		sampleBucket(Time{now.Add(-72 * time.Hour)}, "ancient", "claude-opus-5", 1, 1),
		sampleBucket(Time{}, "zero", "claude-opus-5", 1, 1),
		sampleBucket(minuteAt(now, -1), "good", "claude-opus-5", 1, 1),
	}}
	if accepted := mustIngest(t, store, "mac-1", report, now); accepted != 1 {
		t.Fatalf("accepted %d, want 1", accepted)
	}
	stats, _ := store.Stats("24h", now)
	if len(stats.Series) != 1 || stats.Series[0].SessionID != "good" {
		t.Fatalf("kept the wrong bucket: %+v", stats.Series)
	}
}

func TestABucketWithNoSessionOrModelIsRefused(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	noSession := sampleBucket(minuteAt(now, -1), "", "claude-opus-5", 1, 1)
	noModel := sampleBucket(minuteAt(now, -1), "sess-1", "", 1, 1)
	empty := sampleBucket(minuteAt(now, -1), "sess-1", "claude-opus-5", 0, 0)
	empty.Requests = 0
	report := UsageReport{Label: "studio", Buckets: []UsageBucket{noSession, noModel, empty}}
	if accepted := mustIngest(t, store, "mac-1", report, now); accepted != 0 {
		t.Fatalf("accepted %d, want 0", accepted)
	}
}

func TestUsageSurvivesARestart(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	store := NewSeriesStore(dir, 30*24*time.Hour)
	mustIngest(t, store, "mac-1", UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -5), "sess-1", "claude-opus-5", 100, 10),
		sampleBucket(minuteAt(now, -4), "sess-1", "claude-opus-5", 200, 20),
	}}, now)

	reopened := NewSeriesStore(dir, 30*24*time.Hour)
	stats, err := reopened.Stats("24h", now)
	if err != nil {
		t.Fatal(err)
	}
	if stats.Totals.Input != 300 {
		t.Fatalf("restored %d input tokens, want 300", stats.Totals.Input)
	}
	if len(stats.Series) != 1 || stats.Series[0].MachineLabel != "studio" {
		t.Errorf("machine label lost across the restart: %+v", stats.Series)
	}
}

// An append-only log plus a crash leaves a half-written line. It is worth one bucket, not
// the whole day.
func TestATornLineCostsOnlyItsOwnBucket(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	store := NewSeriesStore(dir, 30*24*time.Hour)
	mustIngest(t, store, "mac-1", UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -5), "sess-1", "claude-opus-5", 100, 10),
	}}, now)

	path := filepath.Join(dir, now.Format("2006-01-02")+seriesFileSuffix)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(raw, []byte(`{"machineID":"mac-1","min`)...),
		0o600); err != nil {
		t.Fatal(err)
	}

	reopened := NewSeriesStore(dir, 30*24*time.Hour)
	stats, _ := reopened.Stats("24h", now)
	if stats.Totals.Input != 100 {
		t.Fatalf("a torn line cost the whole file: %+v", stats.Totals)
	}
}

func TestDayFilesPastRetentionAreDeleted(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	store := NewSeriesStore(dir, 48*time.Hour)
	stale := filepath.Join(dir, "2026-08-01"+seriesFileSuffix)
	if err := os.WriteFile(stale, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mustIngest(t, store, "mac-1", UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -5), "sess-1", "claude-opus-5", 100, 10),
	}}, now)

	store.Sweep(now)
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("a day past retention was kept")
	}
	if _, err := os.Stat(filepath.Join(dir,
		now.Format("2006-01-02")+seriesFileSuffix)); err != nil {
		t.Errorf("today's file was deleted: %v", err)
	}
}

// One API key is one account however many Macs minted their own id for it — the same rule
// the session view follows.
func TestAKeyAccountPoolsAcrossMachinesByFingerprint(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	fingerprint := APIKeyFingerprint("sk-ant-fixture")

	first := sampleBucket(minuteAt(now, -5), "sess-1", "claude-opus-5", 100, 10)
	first.AccountID, first.Kind = "uuid-on-studio", KindAPIKey
	first.AccountFingerprint = ptr(fingerprint)
	second := sampleBucket(minuteAt(now, -5), "sess-2", "claude-opus-5", 200, 20)
	second.AccountID, second.Kind = "uuid-on-laptop", KindAPIKey
	second.AccountFingerprint = ptr(fingerprint)

	mustIngest(t, store, "mac-1", UsageReport{Label: "studio", Buckets: []UsageBucket{first}}, now)
	mustIngest(t, store, "mac-2", UsageReport{Label: "laptop", Buckets: []UsageBucket{second}}, now)

	stats, _ := store.Stats("24h", now)
	if len(stats.Accounts) != 1 {
		t.Fatalf("got %d accounts, want 1: %+v", len(stats.Accounts), stats.Accounts)
	}
	if stats.Accounts[0].Totals.Input != 300 {
		t.Errorf("pooled totals are %+v", stats.Accounts[0].Totals)
	}
	if stats.Accounts[0].Kind != KindAPIKey {
		t.Errorf("kind is %q, want apiKey", stats.Accounts[0].Kind)
	}
	// Two sessions on two Macs are still two lines.
	if len(stats.Series) != 2 {
		t.Errorf("got %d series, want 2", len(stats.Series))
	}
}

func TestAnUnpricedModelIsNamedRatherThanCostedAtZero(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	unpriced := sampleBucket(minuteAt(now, -5), "sess-1", "claude-unknown-9", 100, 10)
	unpriced.CostUSD = nil
	mustIngest(t, store, "mac-1", UsageReport{Label: "studio",
		Buckets: []UsageBucket{unpriced}}, now)

	stats, _ := store.Stats("24h", now)
	if got := stats.Totals.UnpricedModels; len(got) != 1 || got[0] != "claude-unknown-9" {
		t.Fatalf("unpriced models are %v", got)
	}
	if !stats.Series[0].Points[0].Unpriced {
		t.Error("the point does not say its cost is a floor")
	}
	if stats.Totals.CostUSD != 0 {
		t.Errorf("invented a cost of %v", stats.Totals.CostUSD)
	}
}

// Go marshals a nil slice as null, which the client's plain arrays throw on rather than
// reading as empty — the same trap that wedged every client over an empty hook bundle.
func TestAnEmptyStoreMarshalsEveryArray(t *testing.T) {
	store := NewSeriesStore("", 0)
	stats, err := store.Stats("7d", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(stats)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"accounts":[]`, `"series":[]`, `"unpricedModels":[]`} {
		if !strings.Contains(string(encoded), key) {
			t.Errorf("%s missing from %s", key, encoded)
		}
	}
}

func TestAnUnknownRangeIsRefused(t *testing.T) {
	store := NewSeriesStore("", 0)
	if _, err := store.Stats("all-time", time.Now()); err == nil {
		t.Fatal("an unknown range was accepted")
	}
}

// The ceiling is on memory only. Dropping the oldest minutes from the map is recoverable;
// deleting their file is not.
//
// Dense rather than spread out, because that is the shape that reaches the ceiling: a
// fleet works in bursts, so the buckets that fill it sit inside a few days.
func TestTheOldestMinutesAreDroppedAtTheCeiling(t *testing.T) {
	store := NewSeriesStore("", 30*24*time.Hour)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)

	fill := func(sessions, minutes, startOffset int, tag string) {
		for session := 0; session < sessions; session++ {
			buckets := make([]UsageBucket, 0, minutes)
			for i := 0; i < minutes; i++ {
				buckets = append(buckets, sampleBucket(minuteAt(now, -(startOffset+i)),
					fmt.Sprintf("%s-%d", tag, session), "claude-opus-5", 1, 0))
			}
			for from := 0; from < len(buckets); from += maxBucketsPerReport {
				to := from + maxBucketsPerReport
				if to > len(buckets) {
					to = len(buckets)
				}
				mustIngest(t, store, "mac-1", UsageReport{Label: "studio",
					Buckets: buckets[from:to]}, now)
			}
		}
	}
	// More than the ceiling, with the excess entirely older than a day.
	fill(125, 200, 3*24*60, "old")
	fill(100, 1150, 1, "recent")
	store.Sweep(now)

	if store.Count() > maxSeriesBuckets {
		t.Fatalf("holding %d buckets, ceiling is %d", store.Count(), maxSeriesBuckets)
	}
	stats, _ := store.Stats("30d", now)
	if !stats.Truncated {
		t.Error("the answer does not admit the far end is incomplete")
	}
	// A range that does not reach past what was dropped is complete, and says so.
	recent, _ := store.Stats("24h", now)
	if recent.Truncated {
		t.Error("a range inside what is held was called incomplete")
	}
}

func TestUsageIngestAndStatsOverHTTP(t *testing.T) {
	registry, _ := newTestRegistry(t, newStub(nil))
	store := NewSeriesStore(t.TempDir(), 30*24*time.Hour)
	server, _, client := startTestServerWithSeries(t, registry, store)

	now := time.Now().UTC()
	bucket := sampleBucket(Time{now.Add(-3 * time.Minute).Truncate(time.Minute)},
		"sess-1", "claude-opus-5", 120, 12)
	body, err := json.Marshal(UsageReport{Label: "studio",
		Buckets: []UsageBucket{bucket}})
	if err != nil {
		t.Fatal(err)
	}

	response := authed(t, client, http.MethodPost,
		server.URL+apiPrefix+"/machines/mac-1/usage", string(body))
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("ingest answered %d", response.StatusCode)
	}
	var ack UsageIngestResponse
	if err := json.NewDecoder(response.Body).Decode(&ack); err != nil {
		t.Fatal(err)
	}
	if ack.Accepted != 1 {
		t.Fatalf("accepted %d, want 1", ack.Accepted)
	}

	read := authed(t, client, http.MethodGet, server.URL+apiPrefix+"/stats/24h", "")
	defer read.Body.Close()
	var stats UsageStatsResponse
	if err := json.NewDecoder(read.Body).Decode(&stats); err != nil {
		t.Fatal(err)
	}
	if stats.Totals.Input != 120 || len(stats.Series) != 1 {
		t.Fatalf("stats came back as %+v", stats)
	}

	bad := authed(t, client, http.MethodGet, server.URL+apiPrefix+"/stats/nope", "")
	defer bad.Body.Close()
	if bad.StatusCode != http.StatusBadRequest {
		t.Errorf("an unknown range answered %d", bad.StatusCode)
	}
}

// Health is what a client reads to decide whether to report usage at all.
func TestHealthAdvertisesTheUsageFeature(t *testing.T) {
	found := false
	for _, feature := range serverFeatures {
		if feature == featureUsageSeries {
			found = true
		}
	}
	if !found {
		t.Fatalf("%q is not advertised: %v", featureUsageSeries, serverFeatures)
	}
}

// The grid the client draws on comes from here; a disagreement shows up as points at the
// wrong spacing rather than as an error.
func TestTheRangeTableMatchesTheClients(t *testing.T) {
	for _, want := range []struct {
		key   string
		span  time.Duration
		width int64
	}{
		{"24h", 24 * time.Hour, 300},
		{"7d", 7 * 24 * time.Hour, 1800},
		{"30d", 30 * 24 * time.Hour, 7200},
	} {
		span, width, ok := usageRangeSpec(want.key)
		if !ok || span != want.span || width != want.width {
			t.Errorf("%s -> %v/%d, want %v/%d", want.key, span, width, want.span,
				want.width)
		}
	}
}

// Refused, not truncated. A Mac drops from its spool whatever a successful answer
// covered, so keeping the first N of a larger report acknowledges the tail and loses it.
func TestAnOversizedReportIsRefusedRatherThanTruncated(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	buckets := make([]UsageBucket, 0, maxBucketsPerReport+10)
	for i := 0; i < maxBucketsPerReport+10; i++ {
		buckets = append(buckets, sampleBucket(minuteAt(now, -i-1),
			fmt.Sprintf("sess-%d", i), "claude-opus-5", 1, 0))
	}
	_, err := store.Ingest("mac-1", UsageReport{Label: "studio", Buckets: buckets}, now)
	if !errors.Is(err, ErrReportTooLarge) {
		t.Fatalf("an oversized report gave %v", err)
	}
	if store.Count() != 0 {
		t.Errorf("a refused report stored %d buckets", store.Count())
	}
	// One bucket under the ceiling still goes through.
	if accepted := mustIngest(t, store, "mac-1",
		UsageReport{Label: "studio", Buckets: buckets[:maxBucketsPerReport]},
		now); accepted != maxBucketsPerReport {
		t.Fatalf("accepted %d, want %d", accepted, maxBucketsPerReport)
	}
}

func TestControlCharactersAreStrippedFromEveryUsageField(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	bucket := sampleBucket(minuteAt(now, -1), "sess-1", "claude-opus-5", 1, 1)
	bucket.SessionName = "api\ngateway"
	bucket.AccountLabel = "Wo\x00rk"
	mustIngest(t, store, "mac-1", UsageReport{Label: "stu\ndio",
		Buckets: []UsageBucket{bucket}}, now)

	stats, _ := store.Stats("24h", now)
	series := stats.Series[0]
	if series.SessionName != "apigateway" || series.AccountLabel != "Work" ||
		series.MachineLabel != "studio" {
		t.Fatalf("fields came through as %q / %q / %q", series.SessionName,
			series.AccountLabel, series.MachineLabel)
	}
}

// ccmux moves a session to another account when one is refused, which happens mid-minute
// on the same model. Without the account in the identity the whole minute would be booked
// to whichever account happened to serve last.
func TestAnAccountSwitchMidMinuteSplitsTheLine(t *testing.T) {
	store := NewSeriesStore("", 0)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	minute := minuteAt(now, -3)

	first := sampleBucket(minute, "sess-1", "claude-opus-5", 100, 0)
	first.AccountID, first.AccountLabel = "acct-A", "Work"
	first.CostUSD = ptr(1.0)
	second := sampleBucket(minute, "sess-1", "claude-opus-5", 200, 0)
	second.AccountID, second.AccountLabel = "acct-B", "Personal"
	second.CostUSD = ptr(2.0)

	mustIngest(t, store, "mac-1", UsageReport{Label: "studio",
		Buckets: []UsageBucket{first, second}}, now)

	stats, _ := store.Stats("24h", now)
	if len(stats.Series) != 2 {
		t.Fatalf("got %d series, want 2: %+v", len(stats.Series), stats.Series)
	}
	if len(stats.Accounts) != 2 {
		t.Fatalf("got %d accounts, want 2", len(stats.Accounts))
	}
	for _, account := range stats.Accounts {
		switch account.AccountID {
		case "acct-A":
			if account.Totals.Input != 100 || account.Totals.CostUSD != 1 {
				t.Errorf("acct-A got %+v", account.Totals)
			}
		case "acct-B":
			if account.Totals.Input != 200 || account.Totals.CostUSD != 2 {
				t.Errorf("acct-B got %+v", account.Totals)
			}
		default:
			t.Errorf("unexpected account %q", account.AccountID)
		}
	}
	if stats.Totals.CostUSD != 3 {
		t.Errorf("total cost is %v, want 3", stats.Totals.CostUSD)
	}
}

// An endpoint that accepts retries lets one wedged Mac write the disk full while the set
// it keeps re-sending never grows.
func TestARetriedBucketIsNotWrittenTwice(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	store := NewSeriesStore(dir, 30*24*time.Hour)
	report := UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -3), "sess-1", "claude-opus-5", 100, 10),
	}}
	for i := 0; i < 20; i++ {
		mustIngest(t, store, "mac-1", report, now)
	}

	path := filepath.Join(dir, now.Format("2006-01-02")+seriesFileSuffix)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(raw), "\n"); lines != 1 {
		t.Fatalf("wrote %d lines for one bucket re-sent 20 times", lines)
	}
	// A bucket whose counts actually changed is still written.
	grown := report
	grown.Buckets[0].Input = 999
	mustIngest(t, store, "mac-1", grown, now)
	raw, _ = os.ReadFile(path)
	if lines := strings.Count(string(raw), "\n"); lines != 2 {
		t.Fatalf("a changed bucket was skipped: %d lines", lines)
	}
}

// The Mac drops its spool on a successful answer, so a report that only reached memory
// would be lost the next time this restarts.
func TestAReportThatCannotBeStoredIsRefused(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes into an unwritable directory")
	}
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	store := NewSeriesStore(dir, 30*24*time.Hour)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	report := UsageReport{Label: "studio", Buckets: []UsageBucket{
		sampleBucket(minuteAt(now, -3), "sess-1", "claude-opus-5", 100, 10),
	}}
	if _, err := store.Ingest("mac-1", report, now); err == nil {
		t.Fatal("a report that could not be written was acknowledged")
	}

	// And once the disk is writable again the retry is written, rather than skipped as
	// something the store already holds.
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Ingest("mac-1", report, now); err != nil {
		t.Fatalf("the retry failed: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir,
		now.Format("2006-01-02")+seriesFileSuffix))
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(raw), "\n"); lines != 1 {
		t.Fatalf("the retry wrote %d lines, want 1", lines)
	}
}

// A month of log for a busy fleet is millions of buckets. Holding all of them before the
// first prune is how a daemon under MemoryMax=192M is killed on the way up.
func TestReplayStaysInsideTheCeiling(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	// Written by hand, day by day, so the log holds far more than memory may.
	total := maxSeriesBuckets + 20_000
	for i := 0; i < total; i += 5000 {
		var lines []byte
		for j := i; j < i+5000 && j < total; j++ {
			bucket := sampleBucket(minuteAt(now, -j-1), "sess-1", "claude-opus-5", 1, 0)
			encoded, err := json.Marshal(storedUsageBucket{MachineID: "mac-1",
				MachineLabel: "studio", UsageBucket: bucket})
			if err != nil {
				t.Fatal(err)
			}
			lines = append(append(lines, encoded...), '\n')
		}
		day := minuteAt(now, -i-1).Format("2006-01-02") + seriesFileSuffix
		file, err := os.OpenFile(filepath.Join(dir, day),
			os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.Write(lines); err != nil {
			t.Fatal(err)
		}
		file.Close()
	}

	store := NewSeriesStore(dir, 365*24*time.Hour)
	if store.Count() > maxSeriesBuckets {
		t.Fatalf("replay left %d buckets in memory, ceiling is %d", store.Count(),
			maxSeriesBuckets)
	}
	// What survived is the newest, not whatever was read first.
	stats, _ := store.Stats("24h", now)
	if stats.Totals.Requests == 0 {
		t.Fatal("the newest buckets were the ones dropped")
	}
}

// A total that quietly omits a whole session is worse than one that says it is short.
func TestEvictingAWholeSeriesMarksTheRangeIncomplete(t *testing.T) {
	store := NewSeriesStore("", 30*24*time.Hour)
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	for i := 0; i < maxSeriesEntries+5; i++ {
		bucket := sampleBucket(minuteAt(now, -(i%600)-1), fmt.Sprintf("sess-%d", i),
			"claude-opus-5", 1, 0)
		mustIngest(t, store, "mac-1", UsageReport{Label: "studio",
			Buckets: []UsageBucket{bucket}}, now)
	}
	stats, _ := store.Stats("30d", now)
	if !stats.Truncated {
		t.Fatal("evicted series were dropped without saying the total is short")
	}
}

// The client sizes a push against these; it sends at most UsageLedger.maxPerPush (400)
// buckets in at most UsageLedger.maxPushBytes (512 KiB). Since an oversized report is now
// refused rather than truncated, a server ceiling below the client's would refuse every
// push. The Swift suite pins the other side.
func TestTheReportCeilingClearsWhatAClientSends(t *testing.T) {
	if maxBucketsPerReport < 400 {
		t.Fatalf("maxBucketsPerReport is %d, below the client's 400 per push",
			maxBucketsPerReport)
	}
}
