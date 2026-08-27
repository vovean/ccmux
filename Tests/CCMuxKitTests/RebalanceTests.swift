import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Rebalancing running sessions")
struct RebalanceTests {
    private static func session(_ id: String, on account: String, pid: Int32 = 1,
                                policy: String = "opus",
                                autoSwitch: Bool? = nil) -> SessionRecord {
        SessionRecord(id: id, pid: pid, port: 9000, accountID: account,
                      policyName: policy, cwd: "/tmp", autoSwitchOverride: autoSwitch)
    }

    private static func live(_ pid: Int32, _ status: String) -> [Int32: ClaudeSessionInfo] {
        [pid: ClaudeSessionInfo(pid: pid, sessionID: "s", cwd: "/tmp", name: nil,
                                status: status, version: nil, kind: nil, entrypoint: nil,
                                startedAt: nil)]
    }

    private static func plan(_ records: [SessionRecord], _ accounts: [Account],
                             _ usage: [String: UsageSnapshot],
                             scope: Rebalance.Scope,
                             settings: Settings = Settings(),
                             live: [Int32: ClaudeSessionInfo] = [:]) -> Rebalance.Plan {
        Rebalance.plan(sessions: records, accounts: accounts, usage: usage,
                       settings: settings, live: live, scope: scope)
    }

    /// The gap this closes: a session pushed off an exhausted account stays there once
    /// the account recovers, because failover only ever fires on a refusal.
    @Test func aSessionGoesBackOnceItsAccountRecovers() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        // "a" has reset; "b" — where the session landed — is now below the opus floor.
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "b": PolicyEngineTests.snapshot(session: 40, weekly: 99.5)]
        let plan = Self.plan([Self.session("s1", on: "b")], accounts, usage, scope: .idle)
        #expect(plan.moves == [Rebalance.Move(sessionID: "s1", from: "b", to: "a")])
    }

    /// Least-remaining-first: a session on a fresh account is moved onto the drained
    /// one, not the other way round. The menu asks where the session would launch, not
    /// where it would be most comfortable.
    @Test func theDrainedAccountIsStillThePick() {
        let accounts = [PolicyEngineTests.account("fresh"),
                        PolicyEngineTests.account("drained")]
        let usage = ["fresh": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "drained": PolicyEngineTests.snapshot(session: 50, weekly: 60)]
        #expect(Self.plan([Self.session("s1", on: "fresh")], accounts, usage, scope: .idle)
            .moves == [Rebalance.Move(sessionID: "s1", from: "fresh", to: "drained")])
    }

    @Test func aPinnedSessionIsNeverMoved() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "b": PolicyEngineTests.snapshot(session: 40, weekly: 99.5)]
        let records = [Self.session("s1", on: "b", autoSwitch: false)]
        for scope in [Rebalance.Scope.idle, .all] {
            let plan = Self.plan(records, accounts, usage, scope: scope)
            #expect(plan.moves.isEmpty)
            #expect(plan.skipped["s1"] == .pinned)
        }
    }

    /// The global mode governs what ccmux does unprompted. Pressing the menu item is
    /// not that, so it still works with auto-switch off — only a session's own opt-out
    /// stops it.
    @Test func autoSwitchOffDoesNotDisarmTheButton() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "b": PolicyEngineTests.snapshot(session: 40, weekly: 99.5)]
        #expect(Self.plan([Self.session("s1", on: "b")], accounts, usage, scope: .idle,
                          settings: Settings(autoSwitch: .off)).moves.count == 1)
    }

    /// Spending money is an explicit decision, and an API key can never be picked
    /// automatically to get back to — so nothing may move a session off one.
    @Test func aSessionOnAHandPickedAccountStaysPut() {
        let key = Account(id: "key", label: "key", health: .ok, kind: .apiKey)
        let parked = Account(id: "parked", label: "parked", health: .ok, inRotation: false)
        let accounts = [PolicyEngineTests.account("a"), key, parked]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0)]
        let records = [Self.session("s1", on: "key"), Self.session("s2", on: "parked", pid: 2)]
        for scope in [Rebalance.Scope.idle, .all] {
            let plan = Self.plan(records, accounts, usage, scope: scope)
            #expect(plan.moves.isEmpty)
            #expect(plan.skipped == ["s1": .manualAccount, "s2": .manualAccount])
        }
    }

    /// Moving mid-turn drops the prompt cache mid-answer, so "idle only" means it.
    @Test func aBusySessionIsSkippedUnlessAllIsAsked() {
        let accounts = [PolicyEngineTests.account("fresh"),
                        PolicyEngineTests.account("drained")]
        let usage = ["fresh": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "drained": PolicyEngineTests.snapshot(session: 50, weekly: 60)]
        let records = [Self.session("s1", on: "fresh")]
        let busy = Self.live(1, "busy")

        #expect(Self.plan(records, accounts, usage, scope: .idle, live: busy)
            .skipped["s1"] == .busy)
        #expect(Self.plan(records, accounts, usage, scope: .all, live: busy).moves.count == 1)
        // "waiting" is waiting for the user, not mid-turn: nothing is in flight to spoil.
        #expect(Self.plan(records, accounts, usage, scope: .idle, live: Self.live(1, "waiting"))
            .moves.count == 1)
    }

    /// A session parked against a refusal reports `busy` while it retries, so "idle
    /// only" would skip exactly the session that most needs moving. There is no turn to
    /// protect on an account that can serve nothing.
    @Test func aBusySessionOnADeadAccountIsStillRescued() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "b": PolicyEngineTests.snapshot(session: 100, weekly: 100)]
        let plan = Self.plan([Self.session("s1", on: "b")], accounts, usage,
                             scope: .idle, live: Self.live(1, "busy"))
        #expect(plan.moves == [Rebalance.Move(sessionID: "s1", from: "b", to: "a")])
    }

    /// Nothing clears the launch floor: a running session already has somewhere to run,
    /// so the scraps fallback that lets a *launch* proceed has no business here.
    @Test func nothingIsMovedOntoScraps() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 99, weekly: 99.8),
                     "b": PolicyEngineTests.snapshot(session: 40, weekly: 99.5)]
        let plan = Self.plan([Self.session("s1", on: "b")], accounts, usage, scope: .all)
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped["s1"] == .noCandidate)
    }

    /// A Fable session must not be handed an account with only general weekly left.
    @Test func theSessionsOwnPolicyStillDecides() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 100),
                     "b": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 50)]
        let records = [Self.session("s1", on: "a", policy: "fable")]
        #expect(Self.plan(records, accounts, usage, scope: .idle).moves
            == [Rebalance.Move(sessionID: "s1", from: "a", to: "b")])
    }

    @Test func theReportNamesWhatWasLeftAlone() {
        #expect(Rebalance.report(moved: 1, failed: 0, skipped: [:]) == "Moved 1 session.")
        #expect(Rebalance.report(moved: 0, failed: 0,
                                 skipped: ["a": .settled, "b": .settled, "c": .busy])
            == "Moved 0 sessions. Left alone: 1 mid-turn, 2 already where it would launch.")
        #expect(Rebalance.report(moved: 2, failed: 1, skipped: ["a": .pinned])
            == "Moved 2 sessions. 1 could not be moved. Left alone: 1 auto-switch off.")
    }

    /// The escape hatch that rescues a parked session has to be judged on the windows
    /// the session's own policy gates on. A spent Fable week strands a `cc-fable`
    /// session even though its account still answers everything else — and a parked
    /// session reports `busy` while it retries, so without this it is skipped as
    /// mid-turn exactly when it most needs moving.
    @Test func aFableSessionStrandedByItsScopedWindowIsStillRescued() {
        let accounts = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let usage = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 0),
                     "b": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 100)]
        let records = [Self.session("s1", on: "b", policy: "fable")]
        let busy = Self.live(1, "busy")

        #expect(Self.plan(records, accounts, usage, scope: .idle, live: busy).moves
                == [Rebalance.Move(sessionID: "s1", from: "b", to: "a")])
        // An account that can still serve the policy is left alone while it is mid-turn.
        let healthy = ["a": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 0),
                       "b": PolicyEngineTests.snapshot(session: 0, weekly: 0, fable: 40)]
        #expect(Self.plan(records, accounts, healthy, scope: .idle, live: busy)
            .skipped["s1"] == .busy)
    }
}
