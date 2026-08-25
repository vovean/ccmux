import Foundation
import Testing
@testable import CCMuxKit

@Suite("Directory bindings")
struct DirectoryBindingTests {
    private static func account(_ id: String, org: String?) -> Account {
        Account(id: id, label: id, organizationUUID: org, organizationName: org,
                health: .ok)
    }

    @Test func aSessionInABoundDirectoryMatchesIt() {
        let bindings = [DirectoryBinding(path: "/work/alpha", accountID: "a")]
        #expect(DirectoryBindings.match("/work/alpha", in: bindings)?.accountID == "a")
        #expect(DirectoryBindings.match("/work/alpha/backend/cmd", in: bindings)?
            .accountID == "a")
        #expect(DirectoryBindings.match("/work/other", in: bindings) == nil)
    }

    /// Prefix matching on the raw string would capture this, and quietly launch an
    /// unrelated project in the wrong organization.
    @Test func aSiblingWithASharedPrefixIsNotCaptured() {
        let bindings = [DirectoryBinding(path: "/src/app", accountID: "a")]
        #expect(DirectoryBindings.match("/src/app-legacy", in: bindings) == nil)
        #expect(DirectoryBindings.match("/src/application", in: bindings) == nil)
    }

    @Test func theDeepestRuleWins() {
        let bindings = [DirectoryBinding(path: "/work", accountID: "outer"),
                        DirectoryBinding(path: "/work/alpha/api", accountID: "inner"),
                        DirectoryBinding(path: "/work/alpha", accountID: "middle")]
        #expect(DirectoryBindings.match("/work/alpha/api/v2", in: bindings)?
            .accountID == "inner")
        #expect(DirectoryBindings.match("/work/alpha/web", in: bindings)?
            .accountID == "middle")
        #expect(DirectoryBindings.match("/work/beta", in: bindings)?.accountID == "outer")
    }

    @Test func pathsAreNormalizedBeforeComparing() {
        let bindings = [DirectoryBinding(path: "~/work/alpha/", accountID: "a")]
        let home = NSHomeDirectory()
        #expect(DirectoryBindings.match("\(home)/work/alpha/backend", in: bindings)?
            .accountID == "a")
        #expect(DirectoryBindings.match("\(home)/work/alpha/./backend/../api",
                                        in: bindings)?.accountID == "a")
    }

    /// The binding names an account but means an organization: a second seat in the same
    /// organization carries the same approved connectors, so it is a valid launch too.
    @Test func theWholeOrganizationIsUsable() {
        let accounts = [Self.account("a1", org: "org-1"), Self.account("a2", org: "org-1"),
                        Self.account("b1", org: "org-2")]
        let pool = DirectoryBindings.launchPool(
            for: DirectoryBinding(path: "/w", accountID: "a1"), among: accounts)
        #expect(Set(pool.map(\.id)) == ["a1", "a2"])
    }

    /// An unknown organization is not evidence of a shared one, so an account with none
    /// recorded stands alone rather than dragging in every other unknown.
    @Test func anAccountWithNoOrganizationStandsAlone() {
        let accounts = [Self.account("a", org: nil), Self.account("b", org: nil)]
        let pool = DirectoryBindings.launchPool(
            for: DirectoryBinding(path: "/w", accountID: "a"), among: accounts)
        #expect(pool.map(\.id) == ["a"])
    }

    @Test func aBindingToARemovedAccountSelectsNothing() {
        let pool = DirectoryBindings.launchPool(
            for: DirectoryBinding(path: "/w", accountID: "gone"),
            among: [Self.account("a", org: "org-1")])
        #expect(pool.isEmpty)
    }

    /// Two rules for one directory would make the winner depend on array order.
    @Test func rebindingADirectoryReplacesItsRule() {
        var settings = Settings()
        settings.bind("/work/alpha", to: "a")
        settings.bind("/work/alpha/", to: "b")
        #expect(settings.directoryBindings.count == 1)
        #expect(settings.directoryBindings.first?.accountID == "b")
        settings.unbind("/work/./alpha")
        #expect(settings.directoryBindings.isEmpty)
    }

    @Test func settingsWrittenBeforeBindingsExistedStillDecode() throws {
        let json = #"{"warnThresholdPercent":3,"autoSwitch":"immediate"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.directoryBindings.isEmpty)
        #expect(decoded.autoSwitch == .immediate)
    }

    // MARK: - The launch decision

    private static func bound(_ path: String, _ account: String,
                              _ accounts: [Account],
                              _ usage: [String: UsageSnapshot],
                              cwd: String = "/work/alpha/api",
                              policy: Policy = PolicyEngineTests.opus)
        -> DirectoryBindings.Launch {
        var settings = Settings()
        settings.bind(path, to: account)
        return DirectoryBindings.launch(cwd: cwd, settings: settings, accounts: accounts,
                                        usage: usage, policy: policy,
                                        applyingLaunchFloors: true)
    }

    /// The point of the whole feature: a session in a bound project starts in that
    /// organization even when least-remaining-first would have sent it elsewhere.
    @Test func aBoundDirectoryOverridesTheUsualRanking() {
        let accounts = [Self.account("alpha", org: "org-1"),
                        Self.account("other", org: "org-2")]
        // "other" is the more drained account, so it is what ranking alone would pick.
        let usage = ["alpha": PolicyEngineTests.snapshot(session: 5, weekly: 5),
                     "other": PolicyEngineTests.snapshot(session: 70, weekly: 70)]
        #expect(Self.bound("/work/alpha", "alpha", accounts, usage)
                == .use(AccountRanking(accountID: "alpha", headroom: 95,
                                       bindingWindow: "Weekly")))
    }

    /// Connectors are worth more than headroom: an almost-spent account in the right
    /// organization still beats a fresh one in the wrong organization, because the
    /// session can rotate out for quota later without losing them.
    @Test func scrapsInTheBoundOrganizationBeatAFreshAccountOutsideIt() {
        let accounts = [Self.account("alpha", org: "org-1"),
                        Self.account("other", org: "org-2")]
        let usage = ["alpha": PolicyEngineTests.snapshot(session: 99, weekly: 99.8),
                     "other": PolicyEngineTests.snapshot(session: 0, weekly: 0)]
        guard case .use(let choice) = Self.bound("/work/alpha", "alpha", accounts, usage)
        else { return #expect(Bool(false), "expected a bound choice") }
        #expect(choice.accountID == "alpha")
    }

    /// Nothing left in the organization at all. Refusing to launch would be worse than
    /// launching without connectors, but it must be said out loud.
    @Test func anExhaustedOrganizationFallsBackAndSaysSo() {
        let accounts = [Self.account("alpha", org: "org-1"),
                        Self.account("other", org: "org-2")]
        let usage = ["alpha": PolicyEngineTests.snapshot(session: 100, weekly: 100),
                     "other": PolicyEngineTests.snapshot(session: 10, weekly: 10)]
        #expect(Self.bound("/work/alpha", "alpha", accounts, usage)
                == .organizationSpent("org-1"))
    }

    @Test func anUnboundDirectoryIsLeftToTheUsualRanking() {
        let accounts = [Self.account("alpha", org: "org-1")]
        let usage = ["alpha": PolicyEngineTests.snapshot(session: 0, weekly: 0)]
        #expect(Self.bound("/work/alpha", "alpha", accounts, usage, cwd: "/elsewhere")
                == .unbound)
        #expect(DirectoryBindings.launch(cwd: nil, settings: Settings(), accounts: accounts,
                                         usage: usage, policy: PolicyEngineTests.opus)
                == .unbound)
    }

    /// A second seat in the same organization is a valid launch, and ranking picks
    /// between them exactly as it would anywhere else.
    @Test func rankingStillAppliesWithinTheBoundOrganization() {
        let accounts = [Self.account("seat1", org: "org-1"),
                        Self.account("seat2", org: "org-1"),
                        Self.account("other", org: "org-2")]
        let usage = ["seat1": PolicyEngineTests.snapshot(session: 10, weekly: 10),
                     "seat2": PolicyEngineTests.snapshot(session: 40, weekly: 60),
                     "other": PolicyEngineTests.snapshot(session: 90, weekly: 90)]
        guard case .use(let choice) = Self.bound("/work/alpha", "seat1", accounts, usage)
        else { return #expect(Bool(false), "expected a bound choice") }
        #expect(choice.accountID == "seat2")
    }

    /// "Never pick this account on your own, except for this project" — the pairing that
    /// makes a binding worth more than a launch flag.
    @Test func aBindingReachesAnAccountHeldOutOfRotation() {
        let parked = Account(id: "parked", label: "parked", organizationUUID: "org-1",
                             organizationName: "org-1", health: .ok, inRotation: false)
        let accounts = [parked, Self.account("other", org: "org-2")]
        let usage = ["parked": PolicyEngineTests.snapshot(session: 0, weekly: 0),
                     "other": PolicyEngineTests.snapshot(session: 50, weekly: 50)]
        guard case .use(let choice) = Self.bound("/work/alpha", "parked", accounts, usage)
        else { return #expect(Bool(false), "expected the parked account to be reachable") }
        #expect(choice.accountID == "parked")
    }

    /// A binding must not become a way to spend money on every session started in a
    /// directory, so an API key is not bindable and the picker never offers one.
    @Test func aBindingNeverReachesAnAPIKey() {
        let key = Account(id: "key", label: "key", organizationUUID: "org-1",
                          organizationName: "org-1", health: .ok, kind: .apiKey)
        #expect(DirectoryBindings.bindable([key, Self.account("a", org: "org-2")])
            .map(\.id) == ["a"])
        let usage = ["key": PolicyEngineTests.snapshot(session: 0, weekly: 0)]
        #expect(Self.bound("/work/alpha", "key", DirectoryBindings.bindable([key]), usage)
                == .organizationSpent("its bound account"))
    }

    /// When no seat in the organization clears the launch floor, take the one with the
    /// most left — the same scraps rule the unbound path uses. Taking the most drained
    /// seat would start the session on the one refused soonest.
    @Test func theScrapsFallbackTakesTheFullestSeatInTheOrganization() {
        let accounts = [Self.account("nearly", org: "org-1"),
                        Self.account("some", org: "org-1"),
                        Self.account("outside", org: "org-2")]
        // Both org-1 seats are under the opus floors (session ≥ 3%, weeklyAll ≥ 1%).
        let usage = ["nearly": PolicyEngineTests.snapshot(session: 99, weekly: 99.9),
                     "some": PolicyEngineTests.snapshot(session: 98, weekly: 99.5),
                     "outside": PolicyEngineTests.snapshot(session: 0, weekly: 0)]
        // The shared fixture policy has no floors, so this needs the real one.
        guard case .use(let choice) = Self.bound("/work/alpha", "nearly", accounts, usage,
                                                 policy: Policy.defaults[0])
        else { return #expect(Bool(false), "expected a bound choice") }
        #expect(choice.accountID == "some")
    }
}
