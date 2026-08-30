import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("The pooled picture across accounts")
struct UsageSummaryTests {
    private func account(_ id: String, kind: AccountKind = .subscription,
                         inRotation: Bool = true,
                         health: AccountHealth = .ok) -> Account {
        Account(id: id, label: id, health: health, kind: kind, inRotation: inRotation)
    }

    private func row(_ summary: UsageSummary, _ kind: UsageWindow.Kind,
                     model: String? = nil) -> SummaryRow? {
        summary.rows.first { $0.kind == kind && $0.modelName == model }
    }

    /// The live numbers this was designed against: four subscriptions whose weekly usage
    /// is 100 / 26 / 83 / 22. The average is the answer to "how much of my total is gone".
    @Test func windowsAreAveragedAcrossTheAccountsThatHaveThem() {
        let accounts = ["a", "b", "c", "d"].map { account($0) }
        let usage = [
            "a": PolicyEngineTests.snapshot(session: 0, weekly: 100, fable: 86),
            "b": PolicyEngineTests.snapshot(session: 66, weekly: 26, fable: 48),
            "c": PolicyEngineTests.snapshot(session: 10, weekly: 83, fable: 100),
            "d": PolicyEngineTests.snapshot(session: 14, weekly: 22, fable: 19),
        ]
        let summary = UsageSummaries.build(accounts: accounts, usage: usage)

        #expect(summary.contributorCount == 4)
        #expect(row(summary, .session)?.percent == 22.5)
        #expect(row(summary, .weeklyAll)?.percent == 57.75)
        #expect(row(summary, .weeklyScoped, model: "Fable")?.percent == 63.25)
    }

    /// An account held out of rotation or waiting on a sign-in has headroom that cannot be
    /// spent right now, so counting it would inflate the one number this section exists
    /// to give.
    @Test func onlyAccountsCcmuxCouldActuallyPickAreCounted() {
        let accounts = [
            account("live"),
            account("parked", inRotation: false),
            account("expired", health: .needsRelogin),
            account("key", kind: .apiKey),
        ]
        let usage = [
            "live": PolicyEngineTests.snapshot(session: 40, weekly: 40),
            "parked": PolicyEngineTests.snapshot(session: 0, weekly: 0),
            "expired": PolicyEngineTests.snapshot(session: 0, weekly: 0),
            "key": PolicyEngineTests.snapshot(session: 0, weekly: 0),
        ]
        let summary = UsageSummaries.build(accounts: accounts, usage: usage)

        #expect(summary.contributorCount == 1)
        // Averaging in the three excluded zeroes would have read 10%.
        #expect(row(summary, .session)?.percent == 40)
    }

    /// A per-minute ceiling refills continuously and a budget is money, not a server
    /// limit. Pooling either with quota that takes a week to come back is meaningless.
    @Test func perMinuteCeilingsAndBudgetsAreLeftOut() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(kind: .session, label: "5-hour", percent: 20),
            UsageWindow(kind: .apiRequests, label: "Requests/min", percent: 90),
            UsageWindow(kind: .apiTokens, label: "Tokens/min", percent: 90),
            UsageWindow(kind: .budget, label: "Monthly spend", percent: 90),
        ])
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: ["a": snapshot, "b": snapshot])

        #expect(summary.rows.map(\.kind) == [.session])
    }

    // MARK: - The nearest reset

    @Test func theNearestResetIsTheSoonestAndNamesItsAccount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(86_400)
        let accounts = [account("early"), account("late")]
        let usage = [
            "early": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                         percent: 50, resetsAt: soon)]),
            "late": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                        percent: 50, resetsAt: later)]),
        ]
        let summary = UsageSummaries.build(accounts: accounts, usage: usage, now: now)

        #expect(row(summary, .session)?.nearestReset == soon)
        #expect(row(summary, .session)?.nearestResetAccount == "early")
    }

    /// A reset already behind us is a snapshot that has not caught up, not the next
    /// reset — reporting it would show a countdown of zero that never moves.
    @Test func aResetInThePastIsSkippedForTheNextRealOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = now.addingTimeInterval(-3600)
        let real = now.addingTimeInterval(7200)
        let usage = [
            "a": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                     percent: 10, resetsAt: stale)]),
            "b": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                     percent: 10, resetsAt: real)]),
        ]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage, now: now)

        #expect(row(summary, .session)?.nearestReset == real)
    }

    @Test func noKnownResetLeavesItUnstatedRatherThanGuessed() {
        let usage = ["a": PolicyEngineTests.snapshot(session: 10, weekly: 10),
                     "b": PolicyEngineTests.snapshot(session: 10, weekly: 10)]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage)

        #expect(row(summary, .session)?.nearestReset == nil)
    }

    // MARK: - How many can still take work

    @Test func anAccountWithNothingLeftInARequiredWindowCountsAsOut() {
        let usage = [
            "spent": PolicyEngineTests.snapshot(session: 20, weekly: 100),
            "burnt": PolicyEngineTests.snapshot(session: 100, weekly: 20),
            "fine": PolicyEngineTests.snapshot(session: 20, weekly: 20),
        ]
        let summary = UsageSummaries.build(
            accounts: [account("spent"), account("burnt"), account("fine")], usage: usage)

        #expect(summary.contributorCount == 3)
        #expect(summary.exhaustedCount == 2)
        #expect(summary.usableCount == 1)
    }

    /// A model-scoped week being gone does not stop the account serving anything else, so
    /// it must not be counted as out.
    @Test func anExhaustedPerModelWeekDoesNotRetireTheAccount() {
        let usage = ["a": PolicyEngineTests.snapshot(session: 10, weekly: 10, fable: 100),
                     "b": PolicyEngineTests.snapshot(session: 10, weekly: 10, fable: 10)]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage)

        #expect(summary.exhaustedCount == 0)
        #expect(row(summary, .weeklyScoped, model: "Fable")?.withHeadroomCount == 1)
    }

    // MARK: - Shape

    @Test func rowsReadInTheOrderTheWindowsBite() {
        let usage = ["a": PolicyEngineTests.snapshot(session: 1, weekly: 2, fable: 3),
                     "b": PolicyEngineTests.snapshot(session: 1, weekly: 2, fable: 3)]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage)

        #expect(summary.rows.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
    }

    /// One account reports a Fable week and the other does not: the pooled figure is over
    /// the accounts that actually have it, not over everyone.
    @Test func aWindowOnlySomeAccountsHaveIsAveragedOverThoseOnly() {
        let usage = ["a": PolicyEngineTests.snapshot(session: 10, weekly: 10, fable: 80),
                     "b": PolicyEngineTests.snapshot(session: 10, weekly: 10)]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage)

        let fable = row(summary, .weeklyScoped, model: "Fable")
        #expect(fable?.percent == 80)
        #expect(fable?.accountCount == 1)
        #expect(summary.contributorCount == 2)
    }

    @Test func twoModelsGetARowEach() {
        let windows = [
            UsageWindow(kind: .weeklyScoped, label: "Weekly Fable", percent: 20,
                        modelName: "Fable"),
            UsageWindow(kind: .weeklyScoped, label: "Weekly Opus", percent: 60,
                        modelName: "Opus"),
        ]
        let summary = UsageSummaries.build(
            accounts: [account("a"), account("b")],
            usage: ["a": UsageSnapshot(windows: windows),
                    "b": UsageSnapshot(windows: windows)])

        #expect(summary.rows.map(\.modelName) == ["Fable", "Opus"])
        #expect(row(summary, .weeklyScoped, model: "Opus")?.percent == 60)
    }

    @Test func nothingEligibleYieldsNothingToShow() {
        let empty = UsageSummaries.build(accounts: [], usage: [:])
        #expect(empty.rows.isEmpty)
        #expect(empty.contributorCount == 0)

        // Eligible accounts but no usage fetched yet: still nothing to draw.
        let unpolled = UsageSummaries.build(accounts: [account("a"), account("b")],
                                            usage: [:])
        #expect(unpolled.rows.isEmpty)
        #expect(unpolled.contributorCount == 0)
        #expect(unpolled.unpolledCount == 2)
    }

    /// The bar is drawn from a synthetic window, so it has to carry the pooled percent and
    /// no reset of its own — the reset shown beside it belongs to one account.
    @Test func theSyntheticWindowCarriesThePooledFigureAndNoReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let usage = [
            "a": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                     percent: 30,
                                                     resetsAt: now.addingTimeInterval(60))]),
            "b": UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                                     percent: 70,
                                                     resetsAt: now.addingTimeInterval(600))]),
        ]
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: usage, now: now)
        let session = try #require(row(summary, .session))
        let window = session.window

        #expect(window.percent == 50)
        #expect(window.resetsAt == nil)
        #expect(window.headroom == 50)
    }

    // MARK: - A pool has to be a pool

    /// The section presented one account's own numbers as a fleet: two eligible accounts
    /// with only one polled produced "Across 2 subscriptions" over a bar that was account
    /// A's bar verbatim. Reachable the moment a second account is added and its first poll
    /// is still in flight, and durably for a delegated account whose server is unreachable
    /// — pollDelegatedUsage gives up quietly and leaves no snapshot at all.
    @Test func anAccountWithNoSnapshotIsNotCountedAsPartOfThePool() {
        let summary = UsageSummaries.build(
            accounts: [account("polled"), account("silent")],
            usage: ["polled": PolicyEngineTests.snapshot(session: 90, weekly: 90)])

        #expect(summary.contributorCount == 1)
        #expect(summary.unpolledCount == 1)
        // Below two contributors the section hides itself, which is what this drives.
        #expect(summary.contributorCount < 2)
    }

    /// An account nobody has polled is unknown, not healthy. Counting it as able to take
    /// work turned "one of two is exhausted" into "all 2 can take a new session".
    @Test func anUnpolledAccountIsNeverCountedAsHavingHeadroom() {
        let summary = UsageSummaries.build(
            accounts: [account("spent"), account("silent")],
            usage: ["spent": PolicyEngineTests.snapshot(session: 20, weekly: 100)])

        #expect(summary.contributorCount == 1)
        #expect(summary.exhaustedCount == 1)
        #expect(summary.usableCount == 0)
        #expect(summary.unpolledCount == 1)
    }

    // MARK: - Figures from before a reset

    /// A window whose reset has passed still carries its pre-reset percent until the next
    /// poll lands. After a sleep that means every account reads 100% with no countdown —
    /// and announcing "none can take a new session" at the moment everything became free
    /// is exactly backwards.
    @Test func aWindowPastItsResetMarksTheWholePictureStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = now.addingTimeInterval(-60)
        let spent = UsageSnapshot(windows: [
            UsageWindow(kind: .session, label: "5-hour", percent: 100, resetsAt: past),
            UsageWindow(kind: .weeklyAll, label: "Weekly", percent: 100, resetsAt: past),
        ])
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: ["a": spent, "b": spent], now: now)

        #expect(summary.hasStaleFigures)
        // Still pooled and still counted — the UI leads with the staleness instead.
        #expect(summary.exhaustedCount == 2)
    }

    @Test func freshFiguresAreNotFlaggedStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(3600)
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(kind: .session, label: "5-hour", percent: 10, resetsAt: future),
        ])
        let summary = UsageSummaries.build(accounts: [account("a"), account("b")],
                                           usage: ["a": snapshot, "b": snapshot], now: now)

        #expect(!summary.hasStaleFigures)
    }

    /// The pool is only as current as its stalest member, so the screen can say so rather
    /// than presenting hours-old numbers as live.
    @Test func theOldestReadingIsCarried() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        let summary = UsageSummaries.build(
            accounts: [account("a"), account("b")],
            usage: ["a": UsageSnapshot(windows: [UsageWindow(kind: .session,
                                                             label: "5-hour", percent: 10)],
                                       fetchedAt: recent),
                    "b": UsageSnapshot(windows: [UsageWindow(kind: .session,
                                                             label: "5-hour", percent: 10)],
                                       fetchedAt: old)])

        #expect(summary.oldestReading == old)
    }

    /// A limit kind this build does not know about still counts against the account, so it
    /// is pooled — under whatever name the endpoint gave it — rather than silently dropped.
    @Test func anUnrecognisedLimitKindIsPooledUnderItsOwnName() {
        let windows = [
            UsageWindow(kind: .session, label: "5-hour", percent: 10),
            UsageWindow(kind: .other, label: "Org monthly", percent: 40),
        ]
        let summary = UsageSummaries.build(
            accounts: [account("a"), account("b")],
            usage: ["a": UsageSnapshot(windows: windows),
                    "b": UsageSnapshot(windows: windows)])

        let other = summary.rows.first { $0.kind == .other }
        #expect(other?.label == "Org monthly")
        #expect(other?.percent == 40)
        // Unknown kinds sort last, after the windows that are understood.
        #expect(summary.rows.last?.kind == .other)
    }
}
