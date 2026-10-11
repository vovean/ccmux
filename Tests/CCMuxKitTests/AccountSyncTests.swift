import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Account sync planning")
struct AccountSyncTests {
    private func local(_ id: String, kind: AccountKind = .subscription) -> Account {
        Account(id: id, label: id, kind: kind)
    }

    private func remote(_ id: String, kind: AccountKind = .subscription,
                        health: AccountHealth = .ok,
                        fingerprint: String? = nil) -> RemoteAccount {
        RemoteAccount(id: id, label: id, kind: kind, health: health,
                      apiKeyFingerprint: fingerprint)
    }

    private func plan(local: [Account], remote: [RemoteAccount],
                      delegated: Set<String> = [], hidden: Set<String> = [],
                      uploadable: Set<String>? = nil,
                      fingerprints: [String: String] = [:]) -> AccountSync.Plan {
        AccountSync.plan(local: local, remote: remote, delegated: delegated, hidden: hidden,
                         canUpload: { uploadable?.contains($0.id) ?? true },
                         apiKeyFingerprint: { fingerprints[$0] })
    }

    @Test func anAccountOnlyHereIsUploaded() {
        #expect(plan(local: [local("a")], remote: []).actions == [.upload(localID: "a")])
    }

    /// Nothing to upload — a lineage already given up, or one that needs signing in — is
    /// left alone rather than retried every minute.
    @Test func anAccountWithNothingToUploadIsLeftAlone() {
        #expect(plan(local: [local("a")], remote: [], uploadable: []).actions.isEmpty)
    }

    @Test func anAccountOnBothSidesIsHandedOver() {
        #expect(plan(local: [local("a")], remote: [remote("a")]).actions
                == [.handOver(localID: "a", remoteID: "a")])
    }

    @Test func aDelegatedAccountIsRefreshedFromTheServer() {
        #expect(plan(local: [local("a")], remote: [remote("a")], delegated: ["a"]).actions
                == [.refresh(remoteID: "a")])
    }

    @Test func anAccountOnlyOnTheServerIsImportedUnlessRemovedHere() {
        #expect(plan(local: [], remote: [remote("a")]).actions
                == [.importAccount(remoteID: "a")])
        #expect(plan(local: [], remote: [remote("a")], hidden: ["a"]).actions.isEmpty)
    }

    /// A dead server copy is still imported: without a row there is no sign-in button,
    /// and no way to repair it from this Mac.
    @Test func aServerOnlyAccountNeedingSignInIsStillImported() {
        #expect(plan(local: [], remote: [remote("a", health: .needsRelogin)]).actions
                == [.importAccount(remoteID: "a")])
    }

    @Test func aDelegatedAccountTheServerDeletedIsRemovedHere() {
        let result = plan(local: [local("a"), local("b")], remote: [remote("b")],
                          delegated: ["a", "b"])
        #expect(result.actions.contains(.remove(localID: "a")))
        #expect(result.heldBackRemovals.isEmpty)
    }

    /// ccmuxd boots with no accounts when its file is unreadable; mirroring that would
    /// delete every account on every Mac within a minute.
    @Test func aServerThatListsNothingDoesNotEmptyThisMac() {
        let result = plan(local: [local("a"), local("b")], remote: [],
                          delegated: ["a", "b"])
        #expect(result.actions.isEmpty)
        #expect(Set(result.heldBackRemovals) == ["a", "b"])
    }

    @Test func theLastAccountDeletedOnTheServerIsStillRemoved() {
        #expect(plan(local: [local("a")], remote: [], delegated: ["a"]).actions
                == [.remove(localID: "a")])
    }

    /// Handing over to a dead lineage would trade a working credential for a broken one;
    /// uploading this Mac's replaces the dead one instead.
    @Test func aWorkingLocalCopyRepairsADeadServerCopy() {
        #expect(plan(local: [local("a")], remote: [remote("a", health: .needsRelogin)])
                    .actions == [.upload(localID: "a")])
        #expect(plan(local: [local("a")], remote: [remote("a", health: .needsRelogin)],
                     uploadable: []).actions.isEmpty)
    }

    @Test func anAPIKeyIsMatchedByFingerprintAcrossMachines() {
        let result = plan(local: [local("mine", kind: .apiKey)],
                          remote: [remote("theirs", kind: .apiKey, fingerprint: "fp")],
                          fingerprints: ["mine": "fp"])
        #expect(result.actions == [.handOver(localID: "mine", remoteID: "theirs")])
    }

    /// A Keychain read that fails must not read as "the server deleted it".
    @Test func aDelegatedAPIKeyIsMatchedByIdWhenItsFingerprintIsUnreadable() {
        let result = plan(local: [local("k", kind: .apiKey)],
                          remote: [remote("k", kind: .apiKey, fingerprint: "fp")],
                          delegated: ["k"])
        #expect(result.actions == [.refresh(remoteID: "k")])
    }

    @Test func kindsAreNeverConflated() {
        let result = plan(local: [local("x", kind: .apiKey)], remote: [remote("x")],
                          fingerprints: [:])
        #expect(result.actions.contains(.upload(localID: "x")))
        #expect(result.actions.contains(.importAccount(remoteID: "x")))
    }
}

@Suite("Account pool")
struct AccountPoolTests {
    private let accounts = [
        Account(id: "free", label: "free"),
        Account(id: "p1", label: "p1", groupID: "project"),
        Account(id: "p2", label: "p2", inRotation: false, groupID: "project"),
        Account(id: "o1", label: "o1", groupID: "other"),
        Account(id: "key", label: "key", kind: .apiKey),
        Account(id: "unloaded", label: "unloaded", groupID: "not-loaded-yet"),
    ]

    /// Including an account whose group this Mac has not loaded: it stays reserved.
    @Test func aMacWithNoGroupChoosesOnlyUngroupedAccounts() {
        #expect(AccountPool.automatic(accounts, group: nil).map(\.id) == ["free"])
    }

    @Test func aMacLimitedToAGroupChoosesOnlyItsAccountsInRotation() {
        #expect(AccountPool.automatic(accounts, group: "project").map(\.id) == ["p1"])
    }

    @Test func aGroupWithNoAccountsHasNothingToChoose() {
        #expect(AccountPool.automatic(accounts, group: "deleted").isEmpty)
    }

    @Test func aSessionsOwnGroupOverridesTheMacs() {
        let settings = Settings(restrictedGroupID: "project")
        let named = SessionRecord(id: "s", pid: 1, port: 9000, accountID: "o1",
                                  policyName: "opus", cwd: "/", groupID: "other")
        #expect(AccountPool.scope(of: named, settings: settings) == "other")
        #expect(AccountPool.scope(of: nil, settings: settings) == "project")
    }

    @Test func aGroupIsNamedInAnyCaseOrById() {
        let groups = [SubscriptionGroup(id: "g1", name: "Cossacks")]
        #expect(AccountPool.resolve("cossacks", in: groups)?.id == "g1")
        #expect(AccountPool.resolve("g1", in: groups)?.id == "g1")
        #expect(AccountPool.resolve("nope", in: groups) == nil)
    }

    @Test func theCapacitySummaryCountsOnlyThePool() {
        let weekly = [UsageWindow(kind: .weeklyAll, label: "Weekly", percent: 10)]
        let usage = ["free": UsageSnapshot(windows: weekly),
                     "p1": UsageSnapshot(windows: weekly)]
        let summary = UsageSummaries.build(accounts: accounts, usage: usage, group: "project")
        #expect(summary.contributorCount == 1)
    }

    /// Reassign moves a session into this Mac's group, and one launched with `--group`
    /// into its own.
    @Test func rebalanceChoosesFromEachSessionsOwnGroup() {
        let sessions = [
            SessionRecord(id: "s1", pid: 1, port: 9000, accountID: "free",
                          policyName: "opus", cwd: "/tmp"),
            SessionRecord(id: "s2", pid: 2, port: 9001, accountID: "free",
                          policyName: "opus", cwd: "/tmp", groupID: "other"),
        ]
        let plan = Rebalance.plan(sessions: sessions, accounts: accounts, usage: [:],
                                  settings: Settings(restrictedGroupID: "project"),
                                  live: [:], scope: .all)
        #expect(Set(plan.moves.map { "\($0.sessionID)→\($0.to)" }) == ["s1→p1", "s2→o1"])
    }
}

@Suite("Shared account settings")
struct AccountUpdateTests {
    /// The local path for an account the server does not hold yet follows the server's
    /// rules, so the upload carries what the server would have stored.
    @Test func anUpdateAppliesTheServersRules() {
        var account = Account(id: "a", label: "Old", monthlyBudgetUSD: 50, groupID: "g")
        AccountUpdate(label: "  New ", inRotation: false).apply(to: &account)
        #expect(account.label == "New")
        #expect(!account.inRotation)
        #expect(account.monthlyBudgetUSD == 50)
        AccountUpdate(monthlyBudgetUSD: 0, groupID: "").apply(to: &account)
        #expect(account.monthlyBudgetUSD == nil)
        #expect(account.groupID == nil)
    }
}

@Suite("Group settings decode")
struct GroupSettingsDecodingTests {
    /// Files written before groups existed decode, with no group and nothing hidden.
    @Test func olderFilesDecodeWithNoGroup() throws {
        let settings = try JSONStore.decoder.decode(Settings.self, from: Data("{}".utf8))
        #expect(settings.restrictedGroupID == nil)
        #expect(settings.hiddenAccountIDs.isEmpty)
        let account = try JSONStore.decoder.decode(
            Account.self, from: Data(#"{"id":"a","label":"A"}"#.utf8))
        #expect(account.groupID == nil)
        let session = try JSONStore.decoder.decode(SessionRecord.self, from: Data(
            #"{"id":"s","pid":1,"port":9000,"accountID":"a","policyName":"opus","cwd":"/"}"#
                .utf8))
        #expect(session.groupID == nil)
    }

    /// An older shim sends no group; the request still decodes.
    @Test func aNewSessionRequestWithoutAGroupDecodes() throws {
        let old = #"{"newSession":{"policy":"opus","cwd":"/","pid":1}}"#
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(old.utf8))
        #expect(request == .newSession(policy: "opus", cwd: "/", pid: 1, accountID: nil,
                                       group: nil))
    }
}

@Suite("Review fixes for account sync")
struct AccountSyncReviewTests {
    /// The repair case: the server's dead copy was there before the adopt, so finding it
    /// after a failed adopt must not count as the adopt having landed — that would give up
    /// this Mac's only working refresh token.
    @Test func aDeadServerCopyDoesNotProveAnAdoptLanded() {
        let mine = Account(id: "a", label: "a")
        let dead = RemoteAccount(id: "a", label: "a", health: .needsRelogin)
        let healed = RemoteAccount(id: "a", label: "a", health: .ok)
        #expect(AccountSync.adopted(mine, in: [dead], keyFingerprint: nil) == nil)
        #expect(AccountSync.adopted(mine, in: [healed], keyFingerprint: nil)?.id == "a")
    }

    /// Folding a duplicate of one key into the other keeps what both spent, and a mute on
    /// both stays one mute.
    @Test func foldingADuplicateKeyKeepsItsSpendAndOneMute() {
        var kept = Account(id: "s", label: "s", kind: .apiKey, spendLifetimeUSD: 10,
                           spendThisMonth: MonthlySpend(month: "2026-10", amountUSD: 5))
        let duplicate = Account(id: "y", label: "y", kind: .apiKey, spendLifetimeUSD: 40,
                                spendThisMonth: MonthlySpend(month: "2026-10", amountUSD: 40))
        kept.absorbSpend(of: duplicate)
        #expect(kept.spendLifetimeUSD == 50)
        #expect(kept.spendThisMonth?.amountUSD == 45)

        var settings = Settings(mutedAccountIDs: ["y", "s"])
        settings.renumberAccount(from: "y", to: "s")
        #expect(settings.mutedAccountIDs == ["s"])
    }

    @Test func aRenumberedKeyTakesItsBindingsMutesAndSessionsAlong() {
        var settings = Settings(mutedAccountIDs: ["old", "other"],
                                directoryBindings: [DirectoryBinding(path: "/src",
                                                                     accountID: "old")])
        settings.renumberAccount(from: "old", to: "new")
        #expect(settings.mutedAccountIDs == ["new", "other"])
        #expect(settings.directoryBindings.map(\.accountID) == ["new"])

        var session = SessionRecord(id: "s", pid: 1, port: 9000, accountID: "old",
                                    policyName: "any", cwd: "/", seededAccountID: "old")
        session.renumberAccount(from: "old", to: "new")
        #expect(session.accountID == "new" && session.seededAccountID == "new")
    }
}

@Suite("Choosing an account in a group")
struct GroupChoiceTests {
    private let policy = Policy.defaults.first { $0.name == "any" }!

    private func choose(_ accounts: [Account], settings: Settings = Settings(),
                        group: String? = nil, cwd: String? = nil) throws
        -> (choice: AccountRanking, warning: String?) {
        try SessionManager.choose(policy: policy, settings: settings, accounts: accounts,
                                  usage: [:], group: group, excluding: [],
                                  applyingLaunchFloors: true, cwd: cwd,
                                  groupName: { $0 == "g" ? "Project" : nil })
    }

    /// A binding reaches an account held out of rotation, even when nothing else on this
    /// Mac could be chosen.
    @Test func aBindingStillLaunchesWhenThePoolIsEmpty() throws {
        let held = Account(id: "held", label: "held", inRotation: false)
        let settings = Settings(directoryBindings: [DirectoryBinding(path: "/src",
                                                                     accountID: "held")])
        #expect(try choose([held], settings: settings, cwd: "/src/app").choice.accountID
                == "held")
    }

    @Test func anEmptyPoolSaysWhichGroupItIs() {
        #expect(throws: SessionError.self) { try choose([], group: "g") }
        do {
            _ = try choose([Account(id: "x", label: "x", groupID: "other")], group: "g")
        } catch {
            #expect(error.localizedDescription.contains("Project"))
        }
    }

    @Test func aMacLimitedToADeletedGroupIsToldSo() {
        #expect(throws: SessionError.self) { try choose([], group: "gone") }
        do {
            _ = try choose([Account(id: "x", label: "x")], group: "gone")
        } catch {
            #expect(error.localizedDescription.contains("no longer exists"))
        }
    }

    @Test func aBindingOutsideTheGroupIsSaidSo() throws {
        let outside = Account(id: "out", label: "Outside", groupID: "other")
        let inside = Account(id: "in", label: "Inside", groupID: "g")
        let settings = Settings(directoryBindings: [DirectoryBinding(path: "/src",
                                                                     accountID: "out")])
        let result = try choose([outside, inside], settings: settings, group: "g",
                                cwd: "/src")
        #expect(result.choice.accountID == "in")
        #expect(result.warning?.contains("outside this session's group") == true)
    }
}
