import Foundation
import Testing
@testable import CCMuxKit

@Suite("Policy selection")
struct PolicyEngineTests {
    static func account(_ id: String, priority: Int = 0,
                        health: AccountHealth = .ok) -> Account {
        Account(id: id, label: id, priority: priority, health: health)
    }

    static func snapshot(session: Double, weekly: Double, fable: Double? = nil)
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

    static let opus = Policy(name: "opus", requiredWindows: [.session, .weeklyAll])
    static let fable = Policy(name: "fable",
                              requiredWindows: [.session, .weeklyAll, .weeklyScoped],
                              scopedModel: "Fable")

    /// The whole reason the two aliases exist: an account with Fable spent is still a
    /// perfectly good Opus account.
    @Test func opusIgnoresAnExhaustedFableWindow() throws {
        let accounts = [Self.account("a"), Self.account("b")]
        let usage = ["a": Self.snapshot(session: 10, weekly: 20, fable: 100),
                     "b": Self.snapshot(session: 80, weekly: 90, fable: 0)]

        let opusPick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                      policy: Self.opus))
        #expect(opusPick.accountID == "a")

        let fablePick = try #require(PolicyEngine.pick(accounts: accounts, usage: usage,
                                                       policy: Self.fable))
        #expect(fablePick.accountID == "b")
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

    /// An account nothing has measured must not outrank every measured one just for
    /// being unknown — but it should still beat a nearly-spent account, because the
    /// first response header will correct it either way.
    @Test func unmeasuredAccountRanksNeutrally() throws {
        let ranking = try #require(PolicyEngine.headroom(for: Self.account("a"), usage: nil,
                                                         policy: Self.opus))
        #expect(ranking.headroom == PolicyEngine.unknownHeadroom)

        let accounts = [Self.account("unmeasured"), Self.account("healthy")]
        #expect(PolicyEngine.pick(
            accounts: accounts,
            usage: ["healthy": Self.snapshot(session: 10, weekly: 10)],
            policy: Self.opus)?.accountID == "healthy")
        #expect(PolicyEngine.pick(
            accounts: accounts,
            usage: ["healthy": Self.snapshot(session: 95, weekly: 95)],
            policy: Self.opus)?.accountID == "unmeasured")
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

    @Test func minHeadroomIsRespected() {
        let policy = Policy(name: "strict", requiredWindows: [.session], minHeadroom: 25)
        let accounts = [Self.account("a")]
        let usage = ["a": Self.snapshot(session: 80, weekly: 0)]
        #expect(PolicyEngine.pick(accounts: accounts, usage: usage, policy: policy) == nil)
    }
}
