import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Usage ledger")
struct UsageLedgerTests {
    static let noon = Date(timeIntervalSince1970: 1_788_000_000)

    static func identity(session: String = "sess-1", name: String = "api-gateway",
                         model: String = "claude-opus-5",
                         kind: AccountKind = .subscription) -> UsageLedger.Identity {
        UsageLedger.Identity(sessionID: session, sessionName: name,
                             accountID: "acct-1", accountLabel: "Work", kind: kind,
                             model: model)
    }

    static func usage(_ input: Int, _ output: Int = 0) -> TokenUsage {
        TokenUsage(input: input, output: output, cacheRead: 0, cacheWrite5m: 0,
                   cacheWrite1h: 0)
    }

    @Test func requestsInOneMinuteOnOneModelFoldIntoOneBucket() {
        var ledger = UsageLedger()
        ledger.record(Self.usage(100, 10), identity: Self.identity(), at: Self.noon)
        ledger.record(Self.usage(200, 20), identity: Self.identity(),
                      at: Self.noon.addingTimeInterval(30))
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))

        #expect(ledger.pending.count == 1)
        let bucket = try! #require(ledger.pending.first)
        #expect(bucket.requests == 2)
        #expect(bucket.input == 300)
        #expect(bucket.output == 30)
        #expect(bucket.minute == Self.noon)
    }

    /// A session switching model mid-minute is the case ccmux exists for, and one line
    /// averaging two prices would be a line about nothing.
    @Test func twoModelsInOneMinuteAreTwoBuckets() {
        var ledger = UsageLedger()
        ledger.record(Self.usage(100), identity: Self.identity(model: "claude-opus-5"),
                      at: Self.noon)
        ledger.record(Self.usage(100), identity: Self.identity(model: "claude-fable-5-1"),
                      at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        #expect(ledger.pending.count == 2)
        #expect(Set(ledger.pending.map(\.model))
            == ["claude-opus-5", "claude-fable-5-1"])
    }

    /// The property the server's upsert depends on: nothing leaves while it can still
    /// change.
    @Test func aMinuteStillRunningIsNotHandedOver() {
        var ledger = UsageLedger()
        ledger.record(Self.usage(100), identity: Self.identity(), at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(59))
        #expect(ledger.pending.isEmpty)

        ledger.closeElapsed(now: Self.noon.addingTimeInterval(60))
        #expect(ledger.pending.count == 1)
    }

    /// The push takes a snapshot, so a minute that closed while it was in flight must
    /// survive the acknowledgement.
    @Test func acknowledgingDropsOnlyWhatWasTaken() {
        var ledger = UsageLedger()
        ledger.record(Self.usage(100), identity: Self.identity(), at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        let batch = ledger.pending

        ledger.record(Self.usage(500), identity: Self.identity(),
                      at: Self.noon.addingTimeInterval(90))
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(150))
        ledger.acknowledge(batch)

        #expect(ledger.pending.count == 1)
        #expect(ledger.pending.first?.input == 500)
    }

    /// By identity, not by count. A push over a slow link outlives a tick, and the queue
    /// is trimmed from the front at its ceiling — so a count taken before the push can
    /// name buckets that were never sent.
    @Test func aTrimWhileAPushIsInFlightNeverAcknowledgesTheUnsent() {
        var ledger = UsageLedger()
        for minute in 0..<UsageLedger.maxPending {
            ledger.record(Self.usage(1), identity: Self.identity(),
                          at: Self.noon.addingTimeInterval(Double(minute) * 60))
        }
        ledger.closeElapsed(now: Self.noon
            .addingTimeInterval(Double(UsageLedger.maxPending + 1) * 60))
        let batch = ledger.batch
        let following = ledger.pending[batch.count]

        // Three more minutes close while the push is in flight, pushing the queue over
        // its ceiling and trimming its front.
        for extra in 0..<3 {
            ledger.record(Self.usage(1), identity: Self.identity(),
                          at: Self.noon.addingTimeInterval(
                            Double(UsageLedger.maxPending + extra + 1) * 60))
        }
        ledger.closeElapsed(now: Self.noon
            .addingTimeInterval(Double(UsageLedger.maxPending + 10) * 60))
        ledger.acknowledge(batch)

        // The bucket that sat just behind the batch was never sent and must still be here.
        #expect(ledger.pending.contains { $0.minute == following.minute })
        for sent in batch {
            #expect(!ledger.pending.contains { $0.minute == sent.minute })
        }
    }

    /// An upgrade restarts the app while its sessions keep running. A half-minute sent
    /// early would be replaced by the half recorded after the restart, not added to it.
    @Test func aRestartMidMinuteResumesTheSameBucket() throws {
        var before = UsageLedger()
        before.record(Self.usage(100), identity: Self.identity(), at: Self.noon)

        let carried = before.takeSpool()
        var after = UsageLedger(try #require(carried))
        after.record(Self.usage(50), identity: Self.identity(),
                     at: Self.noon.addingTimeInterval(20))
        after.closeElapsed(now: Self.noon.addingTimeInterval(90))

        #expect(after.pending.count == 1)
        #expect(after.pending.first?.input == 150)
        #expect(after.pending.first?.requests == 2)
    }

    @Test func theSpoolRoundTripsThroughJSON() throws {
        var ledger = UsageLedger()
        ledger.record(Self.usage(100, 10), identity: Self.identity(), at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        ledger.record(Self.usage(7), identity: Self.identity(),
                      at: Self.noon.addingTimeInterval(90))

        let taken = ledger.takeSpool()
        let data = try JSONStore.encoder.encode(try #require(taken))
        let restored = UsageLedger(try JSONStore.decoder.decode(UsageLedger.Spool.self,
                                                               from: data))
        #expect(restored.pending.count == 1)
        #expect(restored.pending.first?.input == 100)
        // The open minute came back open.
        var advanced = restored
        advanced.closeElapsed(now: Self.noon.addingTimeInterval(150))
        #expect(advanced.pending.count == 2)
    }

    @Test func anUnpricedModelCarriesNoCost() {
        var ledger = UsageLedger()
        ledger.record(Self.usage(1000, 100),
                      identity: Self.identity(model: "claude-unheard-of-9"),
                      at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        #expect(ledger.pending.first?.costUSD == nil)
    }

    /// Priced when it happened rather than when it is sent, so a later edit to the price
    /// table cannot rewrite what something already cost.
    @Test func aPricedModelCarriesTheCostItHadAtTheTime() {
        var ledger = UsageLedger()
        ledger.record(TokenUsage(input: 1_000_000, output: 0),
                      identity: Self.identity(model: "claude-opus-5"), at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        let cost = try! #require(ledger.pending.first?.costUSD)
        // Opus 5 lists at $5 per million input tokens.
        #expect(abs(cost - 5) < 0.0001)
    }

    @Test func theQueueIsCappedAtItsCeiling() {
        var ledger = UsageLedger()
        for minute in 0..<(UsageLedger.maxPending + 50) {
            ledger.record(Self.usage(1), identity: Self.identity(),
                          at: Self.noon.addingTimeInterval(Double(minute) * 60))
        }
        ledger.closeElapsed(now: Self.noon
            .addingTimeInterval(Double(UsageLedger.maxPending + 100) * 60))
        #expect(ledger.pending.count == UsageLedger.maxPending)
        // The oldest went, not the newest.
        #expect(ledger.pending.first?.minute
            == Self.noon.addingTimeInterval(50 * 60))
    }

    @Test func clearingEmptiesBothHalves() throws {
        var ledger = UsageLedger()
        ledger.record(Self.usage(1), identity: Self.identity(), at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))
        ledger.record(Self.usage(1), identity: Self.identity(),
                      at: Self.noon.addingTimeInterval(90))
        ledger.clear()
        #expect(ledger.pending.isEmpty)
        let emptied = ledger.takeSpool()
        #expect(try #require(emptied).open.isEmpty)
    }

    /// The engine writes the spool only when something changed; a tick that recorded
    /// nothing must not rewrite the file.
    @Test func nothingHappeningLeavesTheLedgerClean() {
        var ledger = UsageLedger()
        #expect(ledger.takeSpool() == nil)
        ledger.closeElapsed(now: Self.noon)
        ledger.acknowledge([])
        ledger.clear()
        #expect(ledger.takeSpool() == nil)

        ledger.record(Self.usage(1), identity: Self.identity(), at: Self.noon)
        #expect(ledger.takeSpool() != nil)
        // Taken once: the next tick has nothing to write.
        #expect(ledger.takeSpool() == nil)
    }

    /// ccmux moves a session to another account when one is refused, mid-minute and on
    /// the same model. Without the account in the key the whole minute would be booked to
    /// whichever account happened to serve last.
    @Test func anAccountSwitchMidMinuteIsTwoBuckets() {
        var ledger = UsageLedger()
        var onA = Self.identity()
        onA.accountID = "acct-A"
        onA.accountLabel = "Work"
        var onB = Self.identity()
        onB.accountID = "acct-B"
        onB.accountLabel = "Personal"

        ledger.record(TokenUsage(input: 1_000_000, output: 0), identity: onA,
                      at: Self.noon)
        ledger.record(TokenUsage(input: 2_000_000, output: 0), identity: onB,
                      at: Self.noon.addingTimeInterval(20))
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))

        #expect(ledger.pending.count == 2)
        let byAccount = Dictionary(uniqueKeysWithValues:
            ledger.pending.map { ($0.accountID, $0) })
        #expect(byAccount["acct-A"]?.input == 1_000_000)
        #expect(byAccount["acct-B"]?.input == 2_000_000)
        // Opus 5 lists at $5 per million input tokens, so neither figure absorbs the
        // other's.
        #expect(abs((byAccount["acct-A"]?.costUSD ?? 0) - 5) < 0.0001)
        #expect(abs((byAccount["acct-B"]?.costUSD ?? 0) - 10) < 0.0001)
    }

    /// The server caps a request body at 1 MiB and this encoder pretty-prints, so a
    /// backlog has to go in bounded pieces or every push is refused forever.
    @Test func aPushIsBoundedAndDrainsOverSeveralTicks() throws {
        var ledger = UsageLedger()
        for minute in 0..<(UsageLedger.maxPerPush + 30) {
            ledger.record(Self.usage(1), identity: Self.identity(),
                          at: Self.noon.addingTimeInterval(Double(minute) * 60))
        }
        ledger.closeElapsed(now: Self.noon
            .addingTimeInterval(Double(UsageLedger.maxPerPush + 60) * 60))
        #expect(ledger.pending.count == UsageLedger.maxPerPush + 30)

        let batch = ledger.batch
        #expect(batch.count == UsageLedger.maxPerPush)
        let encoded = try JSONStore.encoder.encode(
            UsageReport(label: "studio", buckets: batch))
        #expect(encoded.count < 1_048_576)
        #expect(encoded.count <= UsageLedger.maxPushBytes + 4096)

        ledger.acknowledge(batch)
        #expect(ledger.pending.count == 30)
    }

    /// A session name comes from Claude Code's own file and has no length of its own; the
    /// bound above is only safe if the fields inside a bucket are bounded too.
    @Test func identityStringsAreClampedToTheServersCeiling() {
        var ledger = UsageLedger()
        var wordy = Self.identity(name: String(repeating: "n", count: 5000))
        wordy.accountLabel = String(repeating: "a", count: 5000)
        ledger.record(Self.usage(1), identity: wordy, at: Self.noon)
        ledger.closeElapsed(now: Self.noon.addingTimeInterval(90))

        let bucket = try! #require(ledger.pending.first)
        #expect(bucket.sessionName.utf8.count == UsageLedger.maxFieldBytes)
        #expect(bucket.accountLabel.utf8.count == UsageLedger.maxFieldBytes)
    }

    /// Characters, not bytes, is what let a batch of 400 buckets exceed the server's
    /// 1 MiB request cap: 256 Cyrillic characters is 512 bytes, and an emoji label far
    /// more.
    @Test func aBatchOfWordyNonASCIIBucketsStillFits() throws {
        var ledger = UsageLedger()
        var wordy = Self.identity(name: String(repeating: "проект", count: 500))
        wordy.accountLabel = String(repeating: "🙂", count: 500)
        for minute in 0..<UsageLedger.maxPerPush {
            ledger.record(Self.usage(1), identity: wordy,
                          at: Self.noon.addingTimeInterval(Double(minute) * 60))
        }
        ledger.closeElapsed(now: Self.noon
            .addingTimeInterval(Double(UsageLedger.maxPerPush + 5) * 60))
        let encoded = try JSONStore.encoder.encode(
            UsageReport(label: "studio", buckets: ledger.batch))
        #expect(encoded.count < 1_048_576)
    }

    /// Upgrading ccmuxd has to start collecting on its own, rather than waiting for
    /// someone to quit the app on three Macs.
    @Test func theFeatureProbeIsRepeatedOnASlowTimer() {
        let every = ServerAPI.featureProbeInterval
        #expect(PollPolicy.isDue(lastAsked: nil, after: every, now: Self.noon))
        #expect(!PollPolicy.isDue(lastAsked: Self.noon, after: every,
                                  now: Self.noon.addingTimeInterval(60)))
        #expect(PollPolicy.isDue(lastAsked: Self.noon, after: every,
                                 now: Self.noon.addingTimeInterval(every)))
    }

    @Test func aMinuteStartsOnTheMinute() {
        let odd = Date(timeIntervalSince1970: 1_788_000_037.5)
        #expect(UsageLedger.minute(containing: odd)
            == Date(timeIntervalSince1970: 1_788_000_000))
    }
}
