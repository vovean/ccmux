package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Token counts over time, pooled from every Mac.
//
// This is the first thing ccmuxd holds that grows. Everything else is a fixed set of
// accounts, a fixed set of hooks, or a snapshot that replaces itself — so the shape here
// is decided by two limits rather than by what would be convenient: 192 MB of memory
// shared with the VPN processes, and a disk with a couple of gigabytes free.
//
// What keeps it bounded is that a Mac sends only minutes that have already ended. A
// bucket is therefore immutable once it arrives, which makes a re-send an upsert rather
// than an addition, makes the append-only log write each minute exactly once, and means
// nothing has to be reconciled after the fact.
type SeriesStore struct {
	mu      sync.Mutex
	series  map[string]*seriesEntry
	buckets int
	// The earliest minute still guaranteed to be held, once the ceiling has forced
	// anything out. A query reaching back past it is answered with a flag saying so
	// rather than with a quietly short total.
	capFloor  int64
	dir       string
	retention time.Duration
	cache     map[string]cachedStats
	// Serialises the log so two reports cannot interleave halves of a line — held
	// instead of the store lock, so a stalled disk does not also stop every other Mac's
	// ingest and every stats read behind it.
	fileMu sync.Mutex
	// Set when the log cannot be written, so the condition is logged once rather than on
	// every report. Guarded by fileMu.
	appendFailing bool
}

type seriesEntry struct {
	machineID          string
	machineLabel       string
	sessionID          string
	sessionName        string
	accountID          string
	accountFingerprint *string
	// What pools one account across Macs: the fingerprint where there is one, since an
	// API key's account id is minted per Mac.
	accountKey   string
	accountLabel string
	kind         AccountKind
	model        string
	minutes      map[int64]*minuteBucket
	// Unix seconds of the newest minute held, for eviction and for deciding which of two
	// Macs' labels for one session is the current one.
	newest int64
}

// What a minute cost. Split from the bucket so an identical re-send can be recognised by
// comparing this alone — embedding rather than a parallel copy, because a second struct
// listing the same fields is one an added counter can silently skip.
type bucketCounts struct {
	requests     int
	input        int
	output       int
	cacheRead    int
	cacheWrite5m int
	cacheWrite1h int
	costUSD      float64
	// False when the Mac that sent this had no listed price for the model, so a total
	// including it can say it is a floor.
	priced bool
}

type minuteBucket struct {
	bucketCounts
	// Set once this bucket is on disk. A report that could not be written is refused, so
	// this is what makes the retry append it again instead of skipping it as unchanged.
	persisted bool
}

type cachedStats struct {
	response UsageStatsResponse
	at       time.Time
}

const (
	// Thirty days of minute buckets for a fleet of three is a couple of megabytes on
	// disk. The ceiling below is what actually binds.
	defaultSeriesRetention = 30 * 24 * time.Hour
	// Roughly 15 MB of live map at ~120 bytes a bucket. Past this the oldest day is
	// dropped from memory — never from disk, so a restart with a larger ceiling gets it
	// back.
	maxSeriesBuckets = 120_000
	// A session on a model on a machine. Two years of heavy use would not reach this;
	// it exists so a client looping on new session ids cannot exhaust the box.
	maxSeriesEntries = 4096
	// decodeBody caps a request at 1 MiB, which is around 1,700 of these. The belt to
	// that brace, and comfortably above UsageLedger.maxPerPush on the client — the Swift
	// suite pins that side.
	maxBucketsPerReport = 4000
	// Three Macs polling the page do not each pay for the aggregation.
	seriesStatsTTL = 15 * time.Second
	// A minute this far past the server's clock is a Mac whose clock is wrong, not a
	// measurement.
	maxUsageSkew = 5 * time.Minute
	// Per field per minute. Far past anything real, and low enough that summing every
	// bucket in the store cannot come near overflowing.
	maxUsageCount    = 1 << 40
	maxUsageCostUSD  = 1e6
	seriesFileSuffix = ".ndjson"
)

// A line waiting to be written, beside the bucket it came from — so marking it stored
// afterwards is a pointer write rather than a rebuilt key and another map lookup.
type pendingWrite struct {
	record storedUsageBucket
	stored *minuteBucket
}

// ErrReportTooLarge separates a client that sent too much — its own mistake, and fixable
// by sending less — from a server that could not store what it was sent.
var ErrReportTooLarge = errors.New("too many buckets in one report")

// One line of the append-only log: the wire bucket plus which Mac sent it.
type storedUsageBucket struct {
	MachineID    string `json:"machineID"`
	MachineLabel string `json:"machineLabel"`
	UsageBucket
}

func NewSeriesStore(dir string, retention time.Duration) *SeriesStore {
	if retention <= 0 {
		retention = defaultSeriesRetention
	}
	store := &SeriesStore{
		series:    map[string]*seriesEntry{},
		dir:       dir,
		retention: retention,
		cache:     map[string]cachedStats{},
	}
	store.load()
	return store
}

// Ingest folds one Mac's report in and returns how many buckets were kept.
//
// A failure to write the log is returned rather than logged and swallowed. The Mac drops
// its spool on a successful answer, so acknowledging a report that only ever reached
// memory loses those tokens for good the next time the daemon restarts.
func (s *SeriesStore) Ingest(machineID string, report UsageReport,
	now time.Time) (int, error) {
	label := clean(report.Label, maxFieldRunes)
	buckets := report.Buckets
	// Refused rather than truncated. A Mac drops from its spool whatever a successful
	// answer covered, so silently keeping the first N of a larger report is how the tail
	// is acknowledged and then lost.
	if len(buckets) > maxBucketsPerReport {
		return 0, fmt.Errorf("%w: %d (max %d)", ErrReportTooLarge, len(buckets),
			maxBucketsPerReport)
	}

	s.mu.Lock()
	accepted := 0
	unsaved := make([]pendingWrite, 0, len(buckets))
	for _, raw := range buckets {
		bucket, ok := sanitiseUsageBucket(raw, now, s.retention)
		if !ok {
			continue
		}
		accepted++
		// Only what the store did not already hold goes to the log. Without this an
		// endpoint that accepts retries lets one wedged Mac write the disk full while
		// the set it is retrying stays the same size.
		stored, needed := s.upsertLocked(machineID, label, bucket)
		if needed {
			unsaved = append(unsaved, pendingWrite{
				record: storedUsageBucket{MachineID: machineID, MachineLabel: label,
					UsageBucket: bucket},
				stored: stored,
			})
		}
	}
	if accepted > 0 {
		// Cleared rather than recomputed: the next reader pays for the pass, and only if
		// anyone is looking.
		s.cache = map[string]cachedStats{}
	}
	s.mu.Unlock()

	if accepted == 0 {
		return 0, nil
	}
	// Outside the store lock: this touches the disk, and a stalled write must not stop
	// every other Mac's ingest and every stats read behind it.
	if err := s.append(unsaved); err != nil {
		return 0, err
	}
	return accepted, nil
}

// Sweep drops what is past retention and holds the live set inside its ceiling. Called
// from the housekeeping tick.
func (s *SeriesStore) Sweep(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	s.sweepFilesLocked(now)
}

// Stats aggregates onto the range's grid. The answer is cached briefly: three Macs with
// the page open would otherwise each walk every bucket every minute.
func (s *SeriesStore) Stats(rangeKey string, now time.Time) (UsageStatsResponse, error) {
	span, width, ok := usageRangeSpec(rangeKey)
	if !ok {
		return UsageStatsResponse{}, fmt.Errorf("unknown range %q", rangeKey)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if cached, hit := s.cache[rangeKey]; hit && now.Sub(cached.at) < seriesStatsTTL {
		return cached.response, nil
	}
	s.pruneLocked(now)

	// Aligned to the epoch rather than to now, so a point does not shuffle sideways
	// between two refreshes a few seconds apart.
	to := now.Unix()
	from := to - int64(span/time.Second)
	from -= mod(from, width)

	overall := newTotalsBuilder()
	byAccount := map[string]*accountBuilder{}
	out := make([]UsageSeries, 0, len(s.series))

	for _, entry := range s.series {
		if entry.newest < from {
			continue
		}
		account, seen := byAccount[entry.accountKey]
		if !seen {
			account = &accountBuilder{
				row: UsageAccountTotals{
					AccountID:          entry.accountID,
					AccountFingerprint: entry.accountFingerprint,
					AccountLabel:       entry.accountLabel,
					Kind:               entry.kind,
				},
				newest: entry.newest,
				totals: newTotalsBuilder(),
			}
			byAccount[entry.accountKey] = account
		} else if entry.newest > account.newest {
			// Two Macs can name one account differently; the most recent wins.
			account.newest = entry.newest
			account.row.AccountLabel = entry.accountLabel
			account.row.Kind = entry.kind
		}

		slots := map[int64]*bucketCounts{}
		totals := newTotalsBuilder()
		for minute, bucket := range entry.minutes {
			if minute < from || minute > to {
				continue
			}
			slot := minute - mod(minute, width)
			target, seen := slots[slot]
			if !seen {
				target = &bucketCounts{priced: true}
				slots[slot] = target
			}
			target.add(&bucket.bucketCounts)
			totals.add(&bucket.bucketCounts, entry.model)
			overall.add(&bucket.bucketCounts, entry.model)
			account.totals.add(&bucket.bucketCounts, entry.model)
		}
		if len(slots) == 0 {
			continue
		}
		points := make([]UsagePoint, 0, len(slots))
		for at, bucket := range slots {
			points = append(points, UsagePoint{
				At:           Time{Time: time.Unix(at, 0).UTC()},
				Requests:     bucket.requests,
				Input:        bucket.input,
				Output:       bucket.output,
				CacheRead:    bucket.cacheRead,
				CacheWrite5m: bucket.cacheWrite5m,
				CacheWrite1h: bucket.cacheWrite1h,
				CostUSD:      bucket.costUSD,
				Unpriced:     !bucket.priced,
			})
		}
		sort.Slice(points, func(i, j int) bool {
			return points[i].At.Before(points[j].At.Time)
		})
		out = append(out, UsageSeries{
			ID:                 seriesID(entry),
			MachineID:          entry.machineID,
			MachineLabel:       entry.machineLabel,
			SessionID:          entry.sessionID,
			SessionName:        entry.sessionName,
			AccountID:          entry.accountID,
			AccountFingerprint: entry.accountFingerprint,
			AccountLabel:       entry.accountLabel,
			Model:              entry.model,
			Totals:             totals.build(),
			Points:             points,
		})
	}

	// Biggest first: the page draws the top handful and says how many it left out, so
	// this is what decides which lines a reader actually sees.
	sort.Slice(out, func(i, j int) bool {
		left, right := out[i].Totals.Tokens(), out[j].Totals.Tokens()
		if left != right {
			return left > right
		}
		return out[i].ID < out[j].ID
	})

	accounts := make([]UsageAccountTotals, 0, len(byAccount))
	for _, account := range byAccount {
		row := account.row
		row.Totals = account.totals.build()
		accounts = append(accounts, row)
	}
	sort.Slice(accounts, func(i, j int) bool {
		left, right := accounts[i].Totals.Tokens(), accounts[j].Totals.Tokens()
		if left != right {
			return left > right
		}
		return accounts[i].AccountID < accounts[j].AccountID
	})

	response := UsageStatsResponse{
		APIVersion:    apiVersion,
		Range:         rangeKey,
		BucketSeconds: int(width),
		From:          Time{Time: time.Unix(from, 0).UTC()},
		To:            Time{Time: time.Unix(to, 0).UTC()},
		Totals:        overall.build(),
		Accounts:      accounts,
		Series:        out,
		Truncated:     s.capFloor > from,
	}
	s.cache[rangeKey] = cachedStats{response: response, at: now}
	return response, nil
}

// Count reports how many minute buckets are held. Nothing serves it; it is what the
// ceiling is asserted against.
func (s *SeriesStore) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buckets
}

func usageRangeSpec(key string) (span time.Duration, width int64, ok bool) {
	// Must match UsageRange in Sources/CCMuxCore/Server/ServerProtocol.swift. The client
	// sends the key and reads bucketSeconds back, so a disagreement shows up as a chart
	// whose points sit at the wrong spacing rather than as an error.
	switch key {
	case "24h":
		return 24 * time.Hour, 300, true
	case "7d":
		return 7 * 24 * time.Hour, 1800, true
	case "30d":
		return 30 * 24 * time.Hour, 7200, true
	}
	return 0, 0, false
}

// The account is part of the identity, not a property of the line. ccmux moves a session
// between accounts when one is refused, so without it a switch mid-minute would book the
// whole minute to whichever account happened to serve last — and a filter by account
// could not be right either.
func seriesID(entry *seriesEntry) string {
	return entry.machineID + "/" + entry.sessionID + "/" + entry.accountKey + "/" +
		entry.model
}

func seriesKey(machineID, sessionID, account, model string) string {
	return machineID + "\x00" + sessionID + "\x00" + account + "\x00" + model
}

func accountKey(accountID string, fingerprint *string) string {
	if fingerprint != nil && *fingerprint != "" {
		return "fp:" + *fingerprint
	}
	return "id:" + accountID
}

// mod is Go's % corrected for negative operands, which a pre-1970 minute would produce.
func mod(value, by int64) int64 {
	remainder := value % by
	if remainder < 0 {
		remainder += by
	}
	return remainder
}

func (b *bucketCounts) add(other *bucketCounts) {
	b.requests += other.requests
	b.input += other.input
	b.output += other.output
	b.cacheRead += other.cacheRead
	b.cacheWrite5m += other.cacheWrite5m
	b.cacheWrite1h += other.cacheWrite1h
	b.costUSD += other.costUSD
	b.priced = b.priced && other.priced
}

type totalsBuilder struct {
	totals   UsageTotals
	unpriced map[string]bool
}

func newTotalsBuilder() *totalsBuilder {
	return &totalsBuilder{unpriced: map[string]bool{}}
}

func (t *totalsBuilder) add(bucket *bucketCounts, model string) {
	t.totals.Requests += bucket.requests
	t.totals.Input += bucket.input
	t.totals.Output += bucket.output
	t.totals.CacheRead += bucket.cacheRead
	t.totals.CacheWrite5m += bucket.cacheWrite5m
	t.totals.CacheWrite1h += bucket.cacheWrite1h
	t.totals.CostUSD += bucket.costUSD
	if !bucket.priced {
		t.unpriced[model] = true
	}
}

func (t *totalsBuilder) build() UsageTotals {
	out := t.totals
	// Never nil: the client's field is a plain array and decoding null into one throws.
	out.UnpricedModels = make([]string, 0, len(t.unpriced))
	for model := range t.unpriced {
		out.UnpricedModels = append(out.UnpricedModels, model)
	}
	sort.Strings(out.UnpricedModels)
	return out
}

type accountBuilder struct {
	row    UsageAccountTotals
	newest int64
	totals *totalsBuilder
}

// sanitiseUsageBucket is the gate every counted token passes through. Every field here is
// rendered in a window on three Macs, and every number is summed across the whole store.
func sanitiseUsageBucket(bucket UsageBucket, now time.Time,
	retention time.Duration) (UsageBucket, bool) {
	minute := bucket.Minute.UTC().Truncate(time.Minute)
	if minute.IsZero() || minute.After(now.Add(maxUsageSkew)) ||
		minute.Before(now.Add(-retention)) {
		return UsageBucket{}, false
	}
	bucket.Minute = Time{Time: minute}
	bucket.SessionID = clean(bucket.SessionID, maxFieldRunes)
	bucket.SessionName = clean(bucket.SessionName, maxFieldRunes)
	bucket.AccountID = clean(bucket.AccountID, maxFieldRunes)
	bucket.AccountLabel = clean(bucket.AccountLabel, maxFieldRunes)
	bucket.Model = clean(bucket.Model, maxFieldRunes)
	if bucket.AccountFingerprint != nil {
		bucket.AccountFingerprint = ptr(clean(*bucket.AccountFingerprint, maxFieldRunes))
	}
	if bucket.Kind != KindAPIKey {
		bucket.Kind = KindSubscription
	}
	// A bucket with no session or no model has nowhere to go: those two and the machine
	// are the series identity, and an empty one would pool unrelated traffic into a line
	// labelled with nothing.
	if bucket.SessionID == "" || bucket.Model == "" {
		return UsageBucket{}, false
	}
	bucket.Requests = clampCount(bucket.Requests)
	bucket.Input = clampCount(bucket.Input)
	bucket.Output = clampCount(bucket.Output)
	bucket.CacheRead = clampCount(bucket.CacheRead)
	bucket.CacheWrite5m = clampCount(bucket.CacheWrite5m)
	bucket.CacheWrite1h = clampCount(bucket.CacheWrite1h)
	if bucket.CostUSD != nil {
		bucket.CostUSD = ptr(clampFloat(*bucket.CostUSD, 0, maxUsageCostUSD))
	}
	if bucket.Requests == 0 && bucket.Tokens() == 0 {
		return UsageBucket{}, false
	}
	return bucket, true
}

func clampCount(value int) int {
	switch {
	case value < 0:
		return 0
	case value > maxUsageCount:
		return maxUsageCount
	}
	return value
}

// upsertLocked folds one bucket in and hands back what it stored, plus whether the log
// still needs it — false for a re-send of something already held and already written.
func (s *SeriesStore) upsertLocked(machineID, machineLabel string,
	bucket UsageBucket) (*minuteBucket, bool) {
	account := accountKey(bucket.AccountID, bucket.AccountFingerprint)
	key := seriesKey(machineID, bucket.SessionID, account, bucket.Model)
	entry, known := s.series[key]
	if !known {
		if len(s.series) >= maxSeriesEntries {
			s.evictOldestSeriesLocked(maxSeriesEntries - 1)
		}
		entry = &seriesEntry{
			machineID:  machineID,
			sessionID:  bucket.SessionID,
			accountKey: account,
			model:      bucket.Model,
			minutes:    map[int64]*minuteBucket{},
		}
		s.series[key] = entry
	}
	minute := bucket.Minute.Unix()
	renamed := false
	// The newest report names the session, so a rename reaches every line rather than
	// only the minutes recorded after it.
	if minute >= entry.newest {
		renamed = entry.newest != minute || entry.sessionName != bucket.SessionName ||
			entry.machineLabel != machineLabel || entry.accountLabel != bucket.AccountLabel
		entry.newest = minute
		entry.machineLabel = machineLabel
		entry.sessionName = bucket.SessionName
		entry.accountID = bucket.AccountID
		entry.accountFingerprint = bucket.AccountFingerprint
		entry.accountLabel = bucket.AccountLabel
		entry.kind = bucket.Kind
	}
	// Replaced, not added: a Mac re-sends a bucket it could not hand over, and only a
	// minute that has already ended is ever sent, so the newer copy is the same copy.
	counts := bucketCounts{
		requests:     bucket.Requests,
		input:        bucket.Input,
		output:       bucket.Output,
		cacheRead:    bucket.CacheRead,
		cacheWrite5m: bucket.CacheWrite5m,
		cacheWrite1h: bucket.CacheWrite1h,
		priced:       bucket.CostUSD != nil,
	}
	if bucket.CostUSD != nil {
		counts.costUSD = *bucket.CostUSD
	}
	held, existing := entry.minutes[minute]
	if !existing {
		s.buckets++
	} else if held.bucketCounts == counts && held.persisted && !renamed {
		return held, false
	}
	fresh := &minuteBucket{bucketCounts: counts}
	entry.minutes[minute] = fresh
	return fresh, true
}

func (s *SeriesStore) evictOldestSeriesLocked(limit int) {
	for len(s.series) > limit {
		oldestKey, oldest := "", int64(0)
		for key, entry := range s.series {
			if oldestKey == "" || entry.newest < oldest {
				oldestKey, oldest = key, entry.newest
			}
		}
		if oldestKey == "" {
			return
		}
		s.buckets -= len(s.series[oldestKey].minutes)
		delete(s.series, oldestKey)
		// Everything up to that line's last minute is now missing from any answer that
		// reaches back to it, and a total that quietly omits a whole session is worse
		// than one that says it is short.
		if oldest >= s.capFloor {
			s.capFloor = oldest + 1
		}
	}
}

func (s *SeriesStore) pruneLocked(now time.Time) {
	s.dropBeforeLocked(now.Add(-s.retention).Unix())
	if s.buckets <= maxSeriesBuckets {
		return
	}
	// Past the ceiling the oldest minutes go, whatever day they fall in. Dropping whole
	// days instead would do nothing in the case that actually reaches the ceiling: a
	// fleet works in bursts, so a month of buckets sits inside a handful of days, and the
	// cutoff would run out of days to advance through while still over the ceiling.
	//
	// Memory only. The log keeps every day inside retention, so a larger ceiling gets
	// them back on the next start.
	minutes := make([]int64, 0, s.buckets)
	for _, entry := range s.series {
		for minute := range entry.minutes {
			minutes = append(minutes, minute)
		}
	}
	sort.Slice(minutes, func(i, j int) bool { return minutes[i] < minutes[j] })
	// The first minute worth keeping. Dropping everything before it sheds at least the
	// excess — more when several buckets share that minute, which is the honest cut.
	cutoff := minutes[s.buckets-maxSeriesBuckets-1] + 1
	s.dropBeforeLocked(cutoff)
	if cutoff > s.capFloor {
		s.capFloor = cutoff
	}
}

func (s *SeriesStore) dropBeforeLocked(cutoff int64) {
	for key, entry := range s.series {
		for minute := range entry.minutes {
			if minute < cutoff {
				delete(entry.minutes, minute)
				s.buckets--
			}
		}
		if len(entry.minutes) == 0 {
			delete(s.series, key)
		}
	}
}

// MARK: - The append-only log

func (s *SeriesStore) dayFile(at time.Time) string {
	return filepath.Join(s.dir, at.UTC().Format("2006-01-02")+seriesFileSuffix)
}

// One write per day file, because two reports arriving together must not interleave
// halves of a line.
//
// A failure is returned, not logged and forgotten: the caller answers the Mac with it, and
// the Mac keeps its spool rather than dropping tokens that only ever reached memory.
func (s *SeriesStore) append(writes []pendingWrite) error {
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	if s.dir == "" || len(writes) == 0 {
		markStored(writes)
		return nil
	}
	type dayBatch struct {
		payload []byte
		writes  []pendingWrite
	}
	byDay := map[string]*dayBatch{}
	for _, write := range writes {
		encoded, err := json.Marshal(write.record)
		if err != nil {
			return fmt.Errorf("could not encode a usage bucket: %w", err)
		}
		path := s.dayFile(write.record.Minute.Time)
		day, known := byDay[path]
		if !known {
			day = &dayBatch{}
			byDay[path] = day
		}
		day.payload = append(append(day.payload, encoded...), '\n')
		day.writes = append(day.writes, write)
	}
	// Marked day by day rather than once at the end: a report spanning midnight can have
	// its first file written and its second refused, and treating the whole report as
	// unwritten makes every retry append the first file's lines again — growing the log
	// that is already the reason the disk is full.
	for path, day := range byDay {
		file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			_, err = file.Write(day.payload)
			if closeErr := file.Close(); err == nil {
				err = closeErr
			}
		}
		if err != nil {
			if !s.appendFailing {
				s.appendFailing = true
				logError("could not append usage to %s: %v", path, err)
			}
			return fmt.Errorf("could not store usage: %w", err)
		}
		markStored(day.writes)
	}
	if s.appendFailing {
		s.appendFailing = false
		logInfo("usage log writable again")
	}
	return nil
}

// A plain bool write behind the store lock the caller already dropped. Racing a prune
// that deleted the bucket costs one redundant line in the log on the next re-send, which
// is why this does not take the lock back for it.
func markStored(writes []pendingWrite) {
	for _, write := range writes {
		write.stored.persisted = true
	}
}

func (s *SeriesStore) load() {
	if s.dir == "" {
		return
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		logError("could not create %s: %v", s.dir, err)
		s.dir = ""
		return
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		logError("could not read %s: %v", s.dir, err)
		return
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), seriesFileSuffix) {
			names = append(names, entry.Name())
		}
	}
	// Oldest first, so a bucket written twice ends on the newer copy.
	sort.Strings(names)

	now := time.Now()
	restored, skipped := 0, 0
	if len(names) > 0 {
		logInfo("restoring usage from %d day file(s)", len(names))
	}
	for _, name := range names {
		// Pruned as it goes, not once at the end. A month of log for a busy fleet is
		// several million buckets, and holding all of them before the first prune is how
		// a daemon under MemoryMax=192M gets killed on the way up. Oldest file first, so
		// what survives is the newest.
		s.pruneLocked(now)
		file, err := os.Open(filepath.Join(s.dir, name))
		if err != nil {
			logError("could not read %s: %v", name, err)
			continue
		}
		scanner := bufio.NewScanner(file)
		// A line is one bucket; the default 64 KB token is ample, but a corrupted file
		// could hold a long one and the scanner would stop at it silently.
		scanner.Buffer(make([]byte, 0, 8<<10), 1<<20)
		for scanner.Scan() {
			var record storedUsageBucket
			if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
				// A half-written last line is the normal cost of an append-only log and a
				// crash; it is worth one bucket, not the whole day.
				skipped++
				continue
			}
			bucket, ok := sanitiseUsageBucket(record.UsageBucket, now, s.retention)
			if !ok || !ValidMachineID(record.MachineID) {
				skipped++
				continue
			}
			stored, _ := s.upsertLocked(record.MachineID,
				clean(record.MachineLabel, maxFieldRunes), bucket)
			// Already on disk by definition: without this the first report after a
			// restart would rewrite every bucket it happens to touch.
			stored.persisted = true
			restored++
		}
		if err := scanner.Err(); err != nil {
			logError("could not finish reading %s: %v", name, err)
		}
		file.Close()
	}
	s.pruneLocked(now)
	if restored > 0 || skipped > 0 {
		logInfo("restored %d usage bucket(s) from %d file(s), skipped %d",
			restored, len(names), skipped)
	}
}

func (s *SeriesStore) sweepFilesLocked(now time.Time) {
	if s.dir == "" {
		return
	}
	// By retention only, never by the memory ceiling: dropping a day from the map is
	// recoverable, deleting its file is not.
	cutoff := now.Add(-s.retention).UTC().Format("2006-01-02")
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, seriesFileSuffix) {
			continue
		}
		if strings.TrimSuffix(name, seriesFileSuffix) >= cutoff {
			continue
		}
		if err := os.Remove(filepath.Join(s.dir, name)); err != nil {
			logWarn("could not remove %s: %v", name, err)
		}
	}
}
