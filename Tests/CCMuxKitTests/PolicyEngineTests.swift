import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Policy selection")
struct PolicyEngineTests {
    public static func account(_ id: String, priority: Int = 0,
                        health: AccountHealth = .ok) -> Account {
        Account(id: id, label: id, priority: priority, health: health)
    }

    public static func snapshot(session: Double, weekly: Double, fable: Double? = nil)
        -> UsageSnapshot {
        var windows = [
            UsageWindow(kind: .session, label: "5-hour", percent: session),
            UsageWindow(kind: .weeklyAll, label: "Weekly", percent: weekly),
        ]
        if let fable {
            windows.append(UsageWindow(kind: .weeklyScoped, label: "Weekly Fable",
                                       percent: fable, modelName: "Fable"))
        }
        return UsageSnapshot(windows: windows)
    }

    public static let opus = Policy(name: "opus", requiredWindows: [.session, .weeklyAll])
    public static let fable = Policy(name: "fable",
                              requiredWindows: [.session, .weeklyAll, .weeklyScoped],
                              scopedModel: "Fable")

    /// The whole reason the two aliases exist: an account with Fable spent is still a
    /// perfectly good Opus account. "a" is the more-drained one on the windows opus
    /// cares about, so least-first picks it despite its Fable week being gone.
    @Test func opusIgnoresAnExhaustedFableWindow() throws {
        let accounts = [Self.account("a"), Self.account("b")]
        let usage = ["a": Self.snapshot(session: 90, weekly: 90, fable: 100),
                     "b": Self.snapshot(session: 20, weekly: 20, fable: 50)]

        let opusPick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                      policy: Self.opus))
        #expect(opusPick.accountID == "a")

        // Fable cannot use "a" at all, however drained it is: the model's own weekly
        // window is exhausted there, and general weekly headroom is no substitute.
        let fablePick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                       policy: Self.fable))
        #expect(fablePick.accountID == "b")
    }

    /// Drain one subscription before starting the next, so the week does not end with
    /// three half-used accounts.
    @Test func theMostDrainedEligibleAccountIsPickedFirst() throws {
        let accounts = [Self.account("fresh"), Self.account("half"), Self.account("nearly")]
        let usage = ["fresh": Self.snapshot(session: 5, weekly: 5),
                     "half": Self.snapshot(session: 50, weekly: 50),
                     "nearly": Self.snapshot(session: 10, weekly: 96)]
        let ranked = PolicyEngine.rank(accounts: accounts, usage: usage, policy: Self.opus)
        #expect(ranked.map(\.accountID) == ["nearly", "half", "fresh"])
        #expect(try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                               policy: Self.opus)).accountID == "nearly")
    }

    /// No floor: an account with almost nothing left is still preferred while it can
    /// serve at all.
    @Test func anAlmostSpentAccountIsStillPreferred() throws {
        let accounts = [Self.account("scraps"), Self.account("fresh")]
        let usage = ["scraps": Self.snapshot(session: 98, weekly: 30),
                     "fresh": Self.snapshot(session: 1, weekly: 1)]
        #expect(try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                               policy: Self.opus)).accountID == "scraps")
    }

    @Test func exhaustedAccountIsNotEligible() {
        let accounts = [Self.account("a")]
        let usage = ["a": Self.snapshot(session: 100, weekly: 10)]
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage, policy: Self.opus) == nil)
    }

    @Test func headroomIsTheTightestRequiredWindow() throws {
        let ranking = try #require(PolicyEngine.headroom(
            for: Self.account("a"),
            usage: Self.snapshot(session: 40, weekly: 95, fable: 99),
            policy: Self.opus))
        #expect(ranking.headroom == 5)
        #expect(ranking.bindingWindow == "Weekly")
    }

    /// A plan with no per-model cap reports no scoped window at all, which is
    /// unconstrained — not exhausted.
    @Test func missingScopedWindowCountsAsUnconstrained() throws {
        let ranking = try #require(PolicyEngine.headroom(
            for: Self.account("a"),
            usage: Self.snapshot(session: 10, weekly: 10),
            policy: Self.fable))
        #expect(ranking.headroom == 90)
    }

    @Test func accountNeedingReloginIsNeverPicked() {
        let accounts = [Self.account("dead", health: .needsRelogin), Self.account("live")]
        let usage = ["dead": Self.snapshot(session: 0, weekly: 0),
                     "live": Self.snapshot(session: 90, weekly: 90)]
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage,
                                  policy: Self.opus)?.accountID == "live")
    }

    /// An account nothing has measured sorts mid-pack: it is a gamble either way, and
    /// the first response corrects it. So a barely-touched account is left alone in its
    /// favour, while a genuinely drained one still goes first.
    @Test func unmeasuredAccountRanksNeutrally() throws {
        let ranking = try #require(PolicyEngine.headroom(for: Self.account("a"), usage: nil,
                                                         policy: Self.opus))
        #expect(ranking.headroom == PolicyEngine.unknownHeadroom)

        let accounts = [Self.account("unmeasured"), Self.account("healthy")]
        #expect(PolicyEngine.pick(
            accounts: accounts,
            usage: ["healthy": Self.snapshot(session: 10, weekly: 10)],
            policy: Self.opus)?.accountID == "unmeasured")
        #expect(PolicyEngine.pick(
            accounts: accounts,
            usage: ["healthy": Self.snapshot(session: 95, weekly: 95)],
            policy: Self.opus)?.accountID == "healthy")
    }

    @Test func tiesBreakOnPriorityThenName() throws {
        let accounts = [Self.account("zeta", priority: 5), Self.account("alpha", priority: 1),
                        Self.account("beta", priority: 1)]
        let usage = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, Self.snapshot(session: 10, weekly: 10))
        })
        let ranked = PolicyEngine.rank(accounts: accounts, usage: usage, policy: Self.opus)
        #expect(ranked.map(\.accountID) == ["alpha", "beta", "zeta"])
    }

    @Test func exclusionSkipsTheAccountThatJustRanOut() throws {
        let accounts = [Self.account("a"), Self.account("b")]
        let usage = ["a": Self.snapshot(session: 1, weekly: 1),
                     "b": Self.snapshot(session: 50, weekly: 50)]
        let pick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                  policy: Self.opus, excluding: ["a"]))
        #expect(pick.accountID == "b")
    }

    /// Launch floors gate which account a session starts on, per window kind.
    @Test func launchFloorsAreAppliedPerWindow() {
        let accounts = [Self.account("a")]
        let policy = Policy(name: "strict", requiredWindows: [.session, .weeklyAll],
                            launchFloors: ["session": 25])
        // 20% left on the 5-hour window: below the floor at launch, fine for failover.
        let usage = ["a": Self.snapshot(session: 80, weekly: 10)]
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage, policy: policy,
                                  applyingLaunchFloors: true) == nil)
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage, policy: policy) != nil)
    }

    /// The floors you asked for, pinned so a settings-file edit that drops them is loud.
    @Test func defaultFloorsMatchTheIntendedPolicy() throws {
        let settings = Settings()
        let fable = try #require(settings.policy(named: "fable"))
        #expect(fable.floor(for: .session) == 5)
        #expect(fable.floor(for: .weeklyAll) == 3)
        #expect(fable.floor(for: .weeklyScoped) == 3)

        let opus = try #require(settings.policy(named: "opus"))
        #expect(opus.floor(for: .session) == 3)
        #expect(opus.floor(for: .weeklyAll) == 1)
        #expect(opus.floor(for: .weeklyScoped) == 0)
    }

    /// A Fable session needs 5% of the 5-hour window; 4% is not enough to start on.
    @Test func aFableLaunchNeedsMoreRoomThanAnOpusLaunch() {
        let accounts = [Self.account("a")]
        let usage = ["a": Self.snapshot(session: 96, weekly: 10, fable: 10)]
        let settings = Settings()
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage,
                                  policy: settings.policy(named: "fable")!,
                                  applyingLaunchFloors: true) == nil)
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage,
                                  policy: settings.policy(named: "opus")!,
                                  applyingLaunchFloors: true) != nil)
    }

    /// Ranking is on weekly headroom, so a drained 5-hour window does not reshuffle the
    /// order every few hours.
    @Test func rankingIgnoresTheFiveHourWindow() throws {
        let accounts = [Self.account("weeklyDrained"), Self.account("hourDrained")]
        let usage = ["weeklyDrained": Self.snapshot(session: 5, weekly: 80),
                     "hourDrained": Self.snapshot(session: 90, weekly: 20)]
        let ranked = PolicyEngine.rank(accounts: accounts, usage: usage, policy: Self.opus)
        #expect(ranked.map(\.accountID) == ["weeklyDrained", "hourDrained"])
    }
}

@Suite("Exhaustion fallback")
struct EveryWindowPolicyTests {
    /// A session launched as `cc-opus` may switch to Fable in-flight, so the window that
    /// actually ran out can be one its launch policy deliberately ignores. The
    /// every-window policy is what the auto-switch tries first.
    @Test func everyWindowRejectsAnyExhaustedWindow() {
        let account = PolicyEngineTests.account("a")
        let fableSpent = PolicyEngineTests.snapshot(session: 10, weekly: 10, fable: 100)
        #expect(PolicyEngine.headroom(for: account, usage: fableSpent,
                                      policy: PolicyEngine.everyWindow) == nil)
        // The opus policy still accepts it, which is the whole point of the two policies.
        #expect(PolicyEngine.headroom(for: account, usage: fableSpent,
                                      policy: PolicyEngineTests.opus) != nil)
    }

    @Test func everyWindowPrefersAFullyHealthyAccount() throws {
        let accounts = [PolicyEngineTests.account("fable-spent"),
                        PolicyEngineTests.account("healthy")]
        let usage = ["fable-spent": PolicyEngineTests.snapshot(session: 5, weekly: 5,
                                                              fable: 100),
                     "healthy": PolicyEngineTests.snapshot(session: 40, weekly: 40,
                                                           fable: 40)]
        let pick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                  policy: PolicyEngine.everyWindow))
        #expect(pick.accountID == "healthy")
    }

    /// With no per-model cap at all there is nothing extra to satisfy, so the strict
    /// policy must not reject a perfectly good account.
    @Test func everyWindowAcceptsAPlanWithNoPerModelCap() {
        #expect(PolicyEngine.headroom(for: PolicyEngineTests.account("a"),
                                      usage: PolicyEngineTests.snapshot(session: 20,
                                                                        weekly: 20),
                                      policy: PolicyEngine.everyWindow) != nil)
    }
}
