import Foundation
import Testing
@testable import CCMuxKit

@Suite("Session grouping")
struct SessionGroupingTests {
    private func session(_ id: String, account: String, pid: Int32 = 1) -> SessionRecord {
        SessionRecord(id: id, pid: pid, port: 9000, accountID: account,
                      policyName: "opus", cwd: "/tmp")
    }

    private func unmanaged(_ pid: Int32) -> ClaudeSessionInfo {
        ClaudeSessionInfo(pid: pid, sessionID: "s\(pid)", cwd: "/tmp", name: "loose",
                          status: nil, version: nil, kind: nil, entrypoint: nil,
                          startedAt: nil)
    }

    @Test("Groups follow account order and skip accounts with no sessions")
    func ordersByAccount() {
        let accounts = [PolicyEngineTests.account("a"),
                        PolicyEngineTests.account("b"),
                        PolicyEngineTests.account("c")]
        let groups = SessionGrouping.groups(
            accounts: accounts,
            sessions: [session("s1", account: "c", pid: 1),
                       session("s2", account: "a", pid: 2),
                       session("s3", account: "c", pid: 3)],
            unmanaged: [])

        #expect(groups.map(\.id) == ["a", "c"])
        #expect(groups[0].count == 1)
        #expect(groups[1].sessions.map(\.id) == ["s1", "s3"])
    }

    @Test("The unmanaged group comes last and only when it has members")
    func unmanagedGroupPlacement() {
        let accounts = [PolicyEngineTests.account("a")]
        let sessions = [session("s1", account: "a")]

        let without = SessionGrouping.groups(accounts: accounts, sessions: sessions,
                                             unmanaged: [])
        #expect(without.map(\.id) == ["a"])

        let with = SessionGrouping.groups(accounts: accounts, sessions: sessions,
                                          unmanaged: [unmanaged(77)])
        #expect(with.map(\.id) == ["a", SessionGrouping.unmanagedGroupID])
        #expect(with.last?.isUnmanaged == true)
        #expect(with.last?.count == 1)
        #expect(with.first?.isUnmanaged == false)
    }

    @Test("A session whose account is gone still gets a group")
    func orphanSessionsSurvive() {
        let groups = SessionGrouping.groups(
            accounts: [PolicyEngineTests.account("a")],
            sessions: [session("s1", account: "a", pid: 1),
                       session("s2", account: "deleted", pid: 2)],
            unmanaged: [])

        #expect(groups.map(\.id) == ["a", "deleted"])
        #expect(groups[1].title == "Unknown account")
        // Every session must appear exactly once, whatever its account.
        #expect(groups.flatMap(\.sessions).map(\.id).sorted() == ["s1", "s2"])
    }

    @Test("Nothing at all yields no groups")
    func emptyInput() {
        #expect(SessionGrouping.groups(accounts: [PolicyEngineTests.account("a")],
                                       sessions: [], unmanaged: []).isEmpty)
    }

    @Test("The unmanaged group id cannot be an account id")
    func unmanagedIDIsReserved() {
        // Account ids are account UUIDs; a control character can never appear in one.
        #expect(SessionGrouping.unmanagedGroupID.contains { $0.asciiValue.map { $0 < 0x20 } == true })
        #expect(UUID(uuidString: SessionGrouping.unmanagedGroupID) == nil)
    }
}

@Suite("Navigation state")
@MainActor
struct NavigationStateTests {
    @Test("Groups start expanded and toggle both ways")
    func toggling() {
        let nav = NavigationState()
        #expect(nav.isCollapsed("a") == false)
        nav.toggle("a")
        #expect(nav.isCollapsed("a"))
        nav.toggle("a")
        #expect(nav.isCollapsed("a") == false)
    }

    @Test("Jumping from an account expands its group and shows the sessions page")
    func jumpFromAccount() {
        let nav = NavigationState()
        nav.toggle("a")
        nav.toggle("b")
        #expect(nav.page == .accounts)

        nav.showSessions(forAccount: "a")

        #expect(nav.page == .sessions)
        #expect(nav.isCollapsed("a") == false)
        // Only the requested group opens; the rest keep their state.
        #expect(nav.isCollapsed("b"))
    }
}

@Suite("Reachable accounts for a blocked session")
struct ReachableAccountsTests {
    private let accounts = [PolicyEngineTests.account("a"),
                            PolicyEngineTests.account("b"),
                            PolicyEngineTests.account("c")]

    private func record(account: String, override: Bool?) -> SessionRecord {
        SessionRecord(id: "s1", pid: 1, port: 9000, accountID: account,
                      policyName: "opus", cwd: "/tmp", autoSwitchOverride: override)
    }

    @Test("A session that may move can land on any account")
    func movableSeesEveryone() {
        let movable = record(account: "a", override: true)
        #expect(ModelRouting.reachableAccounts(accounts, for: movable,
                                               autoSwitchDefault: false).map(\.id)
                == ["a", "b", "c"])

        let followsGlobal = record(account: "a", override: nil)
        #expect(ModelRouting.reachableAccounts(accounts, for: followsGlobal,
                                               autoSwitchDefault: true).map(\.id)
                == ["a", "b", "c"])
    }

    @Test("A pinned session is down to its own account")
    func pinnedSeesOnlyItsOwn() {
        let pinned = record(account: "b", override: false)
        #expect(ModelRouting.reachableAccounts(accounts, for: pinned,
                                               autoSwitchDefault: true).map(\.id) == ["b"])

        let globallyOff = record(account: "b", override: nil)
        #expect(ModelRouting.reachableAccounts(accounts, for: globallyOff,
                                               autoSwitchDefault: false).map(\.id) == ["b"])
    }

    /// The regression that killed a session: a pinned session on an exhausted account was
    /// quoted another account's availability. That moment is already here, so the reset
    /// was left untouched at the pinned account's real one — 41h out — and Claude Code,
    /// which refuses to wait beyond 24h, abandoned the session instead of waiting.
    @Test("A pinned session is never quoted a stranger's earlier reset")
    func pinnedIsNotQuotedAnotherAccountsReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exhausted = PolicyEngineTests.snapshot(session: 100, weekly: 100)
        let free = PolicyEngineTests.snapshot(session: 0, weekly: 0)
        let usage = ["a": exhausted, "b": free]
        let pair = [PolicyEngineTests.account("a"), PolicyEngineTests.account("b")]
        let pinned = record(account: "a", override: false)

        let everyone = ModelRouting.soonestAvailable(nil, accounts: pair, usage: usage, now: now)
        #expect(everyone?.accountID == "b", "an unpinned session would be sent to b")

        let reachable = ModelRouting.reachableAccounts(pair, for: pinned,
                                                       autoSwitchDefault: true)
        let quoted = ModelRouting.soonestAvailable(nil, accounts: reachable,
                                                   usage: usage, now: now)
        #expect(quoted?.accountID != "b")
        #expect(quoted?.accountID == nil || quoted?.accountID == "a")
    }
}

@Suite("Navigation state pruning")
@MainActor
struct NavigationPruningTests {
    /// Collapse a group, let its sessions end, then have a session land on that account
    /// again: it must not come back folded over a session nobody has seen.
    @Test("A group that disappears forgets it was collapsed")
    func vanishedGroupsForgetCollapse() {
        let nav = NavigationState()
        nav.toggle("a")
        nav.toggle("b")
        #expect(nav.isCollapsed("a"))

        nav.retainOnly(["b"])

        #expect(nav.isCollapsed("a") == false)
        #expect(nav.isCollapsed("b"))
    }

    @Test("Pruning to the same set leaves everything alone")
    func pruningIsStable() {
        let nav = NavigationState()
        nav.toggle("a")
        nav.retainOnly(["a", "b", "c"])
        #expect(nav.isCollapsed("a"))
    }
}
