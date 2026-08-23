import Foundation
import Testing
@testable import CCMuxKit

@Suite("Model-aware limit math")
struct ModelRoutingTests {
    public static func snapshot(session: Double, weekly: Double,
                         scoped: [(String, Double, Date?)] = [],
                         sessionReset: Date? = nil,
                         weeklyReset: Date? = nil) -> UsageSnapshot {
        var windows = [
            UsageWindow(kind: .session, label: "5-hour", percent: session,
                        resetsAt: sessionReset),
            UsageWindow(kind: .weeklyAll, label: "Weekly", percent: weekly,
                        resetsAt: weeklyReset),
        ]
        for (name, percent, reset) in scoped {
            windows.append(UsageWindow(kind: .weeklyScoped, label: "Weekly \(name)",
                                       percent: percent, resetsAt: reset, modelName: name))
        }
        return UsageSnapshot(windows: windows)
    }

    @Test func theModelIsReadFromTheRequestBody() {
        #expect(ModelRouting.model(inRequestBody: Data(#"{"model":"claude-fable-5"}"#.utf8))
                == "claude-fable-5")
        #expect(ModelRouting.model(inRequestBody: Data()) == nil)
        #expect(ModelRouting.model(inRequestBody: Data("not json".utf8)) == nil)
        #expect(ModelRouting.model(inRequestBody: Data(#"{"max_tokens":1}"#.utf8)) == nil)
        #expect(ModelRouting.model(inRequestBody: Data(#"{"model":""}"#.utf8)) == nil)
    }

    /// Matching the display name inside the id keeps working for a future generation
    /// without a lookup table to update.
    @Test func scopedWindowsAreMatchedToModelIds() {
        let fable = UsageWindow(kind: .weeklyScoped, label: "Weekly Fable", percent: 0,
                                modelName: "Fable")
        #expect(ModelRouting.window(fable, governs: "claude-fable-5"))
        #expect(ModelRouting.window(fable, governs: "claude-fable-6"))
        #expect(!ModelRouting.window(fable, governs: "claude-opus-5"))

        let notScoped = UsageWindow(kind: .session, label: "5-hour", percent: 0)
        #expect(!ModelRouting.window(notScoped, governs: "claude-fable-5"))
    }

    /// The heart of it: a spent Fable week must not block an Opus request, and must
    /// block a Fable one.
    @Test func aSpentModelWeekOnlyBlocksThatModel() {
        let usage = Self.snapshot(session: 10, weekly: 20, scoped: [("Fable", 100, nil)])
        #expect(!ModelRouting.canServe("claude-fable-5", usage: usage))
        #expect(ModelRouting.canServe("claude-opus-5", usage: usage))
        #expect(ModelRouting.canServe("claude-sonnet-5", usage: usage))
    }

    @Test func theFiveHourWindowBlocksEveryModel() {
        let usage = Self.snapshot(session: 100, weekly: 10, scoped: [("Fable", 0, nil)])
        #expect(!ModelRouting.canServe("claude-fable-5", usage: usage))
        #expect(!ModelRouting.canServe("claude-opus-5", usage: usage))
    }

    @Test func headroomIsTheTightestGatingWindow() {
        let usage = Self.snapshot(session: 40, weekly: 90, scoped: [("Fable", 99, nil)])
        #expect(ModelRouting.headroom(for: "claude-fable-5", in: usage) == 1)
        #expect(ModelRouting.headroom(for: "claude-opus-5", in: usage) == 10)
    }

    /// An account nothing has measured is allowed through; the response corrects us.
    @Test func unmeasuredAccountsAreNotRefusedPreemptively() {
        #expect(ModelRouting.canServe("claude-fable-5", usage: nil))
        #expect(ModelRouting.headroom(for: "claude-fable-5", in: nil) == nil)
    }

    // MARK: - When an account frees up

    @Test func anAccountWithHeadroomIsAvailableNow() {
        let now = Date()
        let usage = Self.snapshot(session: 10, weekly: 10, scoped: [("Fable", 10, nil)])
        #expect(ModelRouting.availableAt("claude-fable-5", usage: usage, now: now) == now)
    }

    /// Every blocking window has to clear, so the account frees at the last of them.
    @Test func aBlockedAccountFreesWhenItsLastBlockingWindowResets() throws {
        let now = Date()
        let fiveHour = now.addingTimeInterval(2 * 3600)
        let weekly = now.addingTimeInterval(3 * 86400)
        let usage = Self.snapshot(session: 100, weekly: 100,
                                  sessionReset: fiveHour, weeklyReset: weekly)
        #expect(ModelRouting.availableAt("claude-opus-5", usage: usage, now: now) == weekly)

        let onlyFiveHourSpent = Self.snapshot(session: 100, weekly: 50,
                                              sessionReset: fiveHour, weeklyReset: weekly)
        #expect(ModelRouting.availableAt("claude-opus-5", usage: onlyFiveHourSpent, now: now)
                == fiveHour)
    }

    @Test func anUnknownResetMakesAvailabilityUnknown() {
        let usage = Self.snapshot(session: 100, weekly: 10, sessionReset: nil)
        #expect(ModelRouting.availableAt("claude-opus-5", usage: usage) == nil)
    }

    /// An account can be days from resetting while another is only hours from freeing
    /// its 5-hour window. Claude Code decides whether to wait from this number, and
    /// refuses when it is over 24h out — so the answer must be the hours, not the days.
    @Test func soonestAcrossAccountsPrefersTheHoursOverTheDays() throws {
        let now = Date()
        let inThreeDays = now.addingTimeInterval(3 * 86400)
        let inFourHours = now.addingTimeInterval(4 * 3600)
        let accounts = [Account(id: "a", label: "a"), Account(id: "b", label: "b"),
                        Account(id: "c", label: "c")]
        let usage = [
            "a": Self.snapshot(session: 20, weekly: 50,
                               scoped: [("Fable", 100, inThreeDays)]),
            "b": Self.snapshot(session: 20, weekly: 50,
                               scoped: [("Fable", 100, inThreeDays)]),
            // Fable left, but its 5-hour window is spent.
            "c": Self.snapshot(session: 100, weekly: 50,
                               scoped: [("Fable", 40, inThreeDays)],
                               sessionReset: inFourHours),
        ]
        let soonest = try #require(ModelRouting.soonestAvailable("claude-fable-5",
                                                                accounts: accounts,
                                                                usage: usage, now: now))
        #expect(soonest.accountID == "c")
        #expect(soonest.at == inFourHours)
        #expect(soonest.at.timeIntervalSince(now) < 24 * 3600)
    }

    @Test func soonestIgnoresAccountsNeedingRelogin() throws {
        let now = Date()
        let accounts = [Account(id: "dead", label: "dead", health: .needsRelogin),
                        Account(id: "live", label: "live")]
        let usage = ["dead": Self.snapshot(session: 0, weekly: 0),
                     "live": Self.snapshot(session: 100, weekly: 0,
                                           sessionReset: now.addingTimeInterval(600))]
        let soonest = try #require(ModelRouting.soonestAvailable("claude-opus-5",
                                                                accounts: accounts,
                                                                usage: usage, now: now))
        #expect(soonest.accountID == "live")
    }

    @Test func soonestIsNilWhenNothingIsKnowable() {
        let accounts = [Account(id: "a", label: "a")]
        let usage = ["a": Self.snapshot(session: 100, weekly: 10, sessionReset: nil)]
        #expect(ModelRouting.soonestAvailable("claude-opus-5", accounts: accounts,
                                              usage: usage) == nil)
    }
}

@Suite("Failover ordering")
struct FailoverOrderingTests {
    static func account(_ id: String, priority: Int = 0,
                        health: AccountHealth = .ok) -> Account {
        Account(id: id, label: id, priority: priority, health: health)
    }

    /// Drain one subscription before starting on the next.
    @Test func theMostDrainedEligibleAccountComesFirst() {
        let accounts = ["fresh", "half", "nearly"].map { Self.account($0) }
        let usage = [
            "fresh": ModelRoutingTests.snapshot(session: 5, weekly: 5,
                                                scoped: [("Fable", 5, nil)]),
            "half": ModelRoutingTests.snapshot(session: 5, weekly: 5,
                                               scoped: [("Fable", 50, nil)]),
            "nearly": ModelRoutingTests.snapshot(session: 5, weekly: 5,
                                                 scoped: [("Fable", 97, nil)]),
        ]
        let ranked = ModelRouting.rankLeastRemaining("claude-fable-5", accounts: accounts,
                                                     usage: usage)
        #expect(ranked.map(\.id) == ["nearly", "half", "fresh"])
    }

    /// The rule the user cares most about: a Fable session must never land on an account
    /// that only has general weekly headroom, however drained that account is.
    @Test func aFableRequestSkipsAccountsWithNoFableLeft() {
        let accounts = ["noFable", "hasFable"].map { Self.account($0) }
        let usage = [
            // The most drained on the general windows, but its Fable week is gone.
            "noFable": ModelRoutingTests.snapshot(session: 90, weekly: 95,
                                                  scoped: [("Fable", 100, nil)]),
            "hasFable": ModelRoutingTests.snapshot(session: 5, weekly: 5,
                                                   scoped: [("Fable", 20, nil)]),
        ]
        #expect(ModelRouting.rankLeastRemaining("claude-fable-5", accounts: accounts,
                                                usage: usage).map(\.id) == ["hasFable"])
        // The same account is fine for Opus, and is preferred there for being drained.
        #expect(ModelRouting.rankLeastRemaining("claude-opus-5", accounts: accounts,
                                                usage: usage).map(\.id)
                == ["noFable", "hasFable"])
    }

    /// No floor: an account with a sliver left is still preferred while it can serve.
    @Test func thereIsNoMinimumHeadroomToBePreferred() {
        let accounts = ["scraps", "fresh"].map { Self.account($0) }
        let usage = ["scraps": ModelRoutingTests.snapshot(session: 99, weekly: 10),
                     "fresh": ModelRoutingTests.snapshot(session: 1, weekly: 1)]
        #expect(ModelRouting.rankLeastRemaining("claude-opus-5", accounts: accounts,
                                                usage: usage).first?.id == "scraps")
    }

    @Test func exhaustedAndUnhealthyAccountsAreExcluded() {
        let accounts = [Self.account("spent"), Self.account("dead", health: .needsRelogin),
                        Self.account("ok")]
        let usage = ["spent": ModelRoutingTests.snapshot(session: 100, weekly: 10),
                     "dead": ModelRoutingTests.snapshot(session: 90, weekly: 10),
                     "ok": ModelRoutingTests.snapshot(session: 10, weekly: 10)]
        #expect(ModelRouting.rankLeastRemaining("claude-opus-5", accounts: accounts,
                                                usage: usage).map(\.id) == ["ok"])
    }

    @Test func alreadyTriedAccountsAreExcluded() {
        let accounts = ["a", "b"].map { Self.account($0) }
        let usage = ["a": ModelRoutingTests.snapshot(session: 90, weekly: 10),
                     "b": ModelRoutingTests.snapshot(session: 10, weekly: 10)]
        #expect(ModelRouting.rankLeastRemaining("claude-opus-5", accounts: accounts,
                                                usage: usage, excluding: ["a"])
                .map(\.id) == ["b"])
    }

    @Test func tiesBreakOnPriority() {
        let accounts = [Self.account("late", priority: 9), Self.account("early", priority: 1)]
        let usage = ["late": ModelRoutingTests.snapshot(session: 50, weekly: 10),
                     "early": ModelRoutingTests.snapshot(session: 50, weekly: 10)]
        #expect(ModelRouting.rankLeastRemaining("claude-opus-5", accounts: accounts,
                                                usage: usage).map(\.id)
                == ["early", "late"])
    }
}

@Suite("Keeping the 5-hour window rolling")
struct WindowProbeTests {
    static func account(_ health: AccountHealth = .ok) -> Account {
        Account(id: "a", label: "a", health: health)
    }

    static func snapshot(sessionPercent: Double, resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                            percent: sessionPercent, resetsAt: resetsAt)])
    }

    /// A stopped clock reports no reset time at all — that, not zero utilization, is the
    /// signal. Measured: before the probe `five_hour.resets_at` was null; after it, a real
    /// timestamp with utilization still 0%.
    @Test func aStoppedClockIsProbed() {
        #expect(WindowProbe.shouldProbe(account: Self.account(),
                                        usage: Self.snapshot(sessionPercent: 0,
                                                             resetsAt: nil),
                                        lastProbe: nil))
    }

    /// A started but unused window reports 0% *with* a reset time, and must not be probed
    /// again — that would be a probe every tick, forever.
    @Test func aRunningButUnusedClockIsLeftAlone() {
        #expect(!WindowProbe.shouldProbe(
            account: Self.account(),
            usage: Self.snapshot(sessionPercent: 0, resetsAt: Date().addingTimeInterval(3600)),
            lastProbe: nil))
    }

    @Test func anAccountInUseIsLeftAlone() {
        #expect(!WindowProbe.shouldProbe(
            account: Self.account(),
            usage: Self.snapshot(sessionPercent: 42, resetsAt: Date().addingTimeInterval(900)),
            lastProbe: nil))
    }

    @Test func anUnmeasuredAccountIsNotProbed() {
        // A poll has to land first, or a stopped clock is indistinguishable from an
        // account nothing knows anything about.
        #expect(!WindowProbe.shouldProbe(account: Self.account(), usage: nil,
                                         lastProbe: nil))
        #expect(!WindowProbe.shouldProbe(account: Self.account(),
                                         usage: UsageSnapshot(windows: []), lastProbe: nil))
    }

    @Test func anAccountNeedingReloginIsNotProbed() {
        #expect(!WindowProbe.shouldProbe(account: Self.account(.needsRelogin),
                                         usage: Self.snapshot(sessionPercent: 0,
                                                              resetsAt: nil),
                                         lastProbe: nil))
    }

    /// Guard against probing in a loop if an account ever keeps reporting no reset time.
    @Test func probesAreSpacedOut() {
        let usage = Self.snapshot(sessionPercent: 0, resetsAt: nil)
        let now = Date()
        #expect(!WindowProbe.shouldProbe(account: Self.account(), usage: usage,
                                         lastProbe: now.addingTimeInterval(-60), now: now))
        #expect(WindowProbe.shouldProbe(
            account: Self.account(), usage: usage,
            lastProbe: now.addingTimeInterval(-WindowProbe.minimumInterval - 1), now: now))
    }
}
