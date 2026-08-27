import Foundation
import Testing
@testable import CCMuxKit

@Suite("Moving accounts to another Mac")
struct AccountTransferTests {
    private static func entry(_ id: String, email: String? = nil,
                              kind: AccountKind = .subscription,
                              key: String? = nil, priority: Int = 0)
        -> AccountBundle.Entry {
        AccountBundle.Entry(id: id, label: id, email: email, priority: priority,
                            kind: kind, apiKey: key)
    }

    private static func local(_ id: String, email: String? = nil) -> Account {
        Account(id: id, label: id, email: email, health: .ok)
    }

    /// The whole point of the feature: an account already signed in on the target is left
    /// alone, and everything else is offered as work to do.
    @Test func whatIsAlreadyThereIsNeverTouched() {
        let bundle = AccountBundle(accounts: [
            Self.entry("a", email: "a@x.test", priority: 0),
            Self.entry("b", email: "b@x.test", priority: 1),
            Self.entry("key", kind: .apiKey, key: "sk-ant-secret", priority: 2),
        ])
        let plan = AccountTransfer.plan(bundle, existing: [Self.local("a", email: "a@x.test")])

        #expect(plan.steps.map(\.disposition) == [.present, .signIn, .addKey])
        #expect(plan.present.map(\.entry.id) == ["a"])
        #expect(plan.actionable.map(\.entry.id) == ["b", "key"])
    }

    /// An API-key account's id is generated on whichever machine created it, so the id
    /// will not match; the address is what identifies it.
    @Test func anAccountIsRecognisedByEmailWhenTheIdDiffers() {
        let bundle = AccountBundle(accounts: [Self.entry("new-id", email: "Same@X.test")])
        let plan = AccountTransfer.plan(bundle,
                                        existing: [Self.local("old-id", email: "same@x.test")])
        #expect(plan.steps.first?.disposition == .present)
    }

    @Test func anEmptyEmailIsNotAMatch() {
        let bundle = AccountBundle(accounts: [Self.entry("x", email: "")])
        let plan = AccountTransfer.plan(bundle, existing: [Self.local("y", email: "")])
        #expect(plan.steps.first?.disposition == .signIn)
    }

    @Test func aKeyExportedWithoutSecretsHasToBePastedIn() {
        let bundle = AccountBundle(accounts: [Self.entry("k", kind: .apiKey, key: nil)])
        #expect(AccountTransfer.plan(bundle, existing: []).steps.first?.disposition
                == .needsKey)
    }

    // MARK: - Export

    /// A subscription's credential must never reach the file. Two machines sharing one
    /// refresh lineage kill each other's sign-in; a static API key is safe on both.
    @Test func onlyAnApiKeyIsEverWritten() throws {
        var subscription = Account(id: "sub", label: "sub", health: .ok)
        subscription.chromeProfileDirectory = "Profile 2"
        let key = Account(id: "key", label: "key", health: .ok, kind: .apiKey)
        let profiles = [ChromeProfile(directory: "Profile 2", name: "work",
                                      email: "me@work.test")]

        var asked: [String] = []
        let bundle = AccountTransfer.bundle(
            accounts: [subscription, key], settings: Settings(), profiles: profiles,
            includePolicies: false,
            apiKey: { id in asked.append(id); return "sk-ant-\(id)" })

        #expect(asked == ["key"])   // never even asked about the subscription
        #expect(bundle.accounts.first { $0.id == "sub" }?.apiKey == nil)
        #expect(bundle.accounts.first { $0.id == "key" }?.apiKey == "sk-ant-key")
        #expect(bundle.carriesSecrets)

        let json = String(decoding: try bundle.encoded(), as: UTF8.self)
        for forbidden in ["refreshToken", "accessToken", "refresh_token"] {
            #expect(!json.contains(forbidden))
        }
    }

    /// The profile directory is machine-local — "Profile 3" is a different account on
    /// every Mac — so the name and address travel and the directory does not.
    @Test func theChromeProfileTravelsByNameNotByDirectory() throws {
        var account = Account(id: "a", label: "a", health: .ok)
        account.chromeProfileDirectory = "Profile 7"
        let bundle = AccountTransfer.bundle(
            accounts: [account], settings: Settings(),
            profiles: [ChromeProfile(directory: "Profile 7", name: "personal",
                                     email: "me@home.test")],
            includePolicies: false, apiKey: { _ in nil })

        let entry = try #require(bundle.accounts.first)
        #expect(entry.chromeProfileName == "personal")
        #expect(entry.chromeProfileEmail == "me@home.test")
        let json = String(decoding: try bundle.encoded(), as: UTF8.self)
        #expect(!json.contains("Profile 7"))
    }

    @Test func settingsAreOptionalSoAnImportNeedNotClobberThem() {
        let bare = AccountTransfer.bundle(accounts: [], settings: Settings(), profiles: [],
                                          includePolicies: false, apiKey: { _ in nil })
        #expect(bare.policies == nil)
        #expect(bare.thresholds == nil)

        var settings = Settings()
        settings.warnThresholdPercent = 12
        settings.autoSwitch = .atTurnBoundary
        let full = AccountTransfer.bundle(accounts: [], settings: settings, profiles: [],
                                          includePolicies: true, apiKey: { _ in nil })
        var target = Settings()
        full.thresholds?.apply(to: &target)
        #expect(target.warnThresholdPercent == 12)
        #expect(target.autoSwitch == .atTurnBoundary)
        // Never carried: absolute paths and a per-network proxy mean nothing over there.
        #expect(target.directoryBindings.isEmpty)
        #expect(target.upstreamProxy == nil)
    }

    @Test func anImportedEntryBecomesACleanAccount() {
        let entry = AccountBundle.Entry(id: "a", label: "work", email: "a@x.test",
                                        subscriptionType: "team", priority: 3,
                                        inRotation: false, monthlyBudgetUSD: 50)
        let account = AccountTransfer.account(from: entry, chromeProfileDirectory: "Profile 4")
        #expect(account.id == "a")
        #expect(account.priority == 3)
        #expect(account.inRotation == false)
        #expect(account.monthlyBudgetUSD == 50)
        #expect(account.chromeProfileDirectory == "Profile 4")
        // Facts about the other machine, not about this one.
        #expect(account.spendLifetimeUSD == 0)
        #expect(account.health == .unknown)
    }

    /// Round-trips through the one pair of coders, which is the point of them existing:
    /// a caller configuring its own would write a file the other machine cannot read.
    @Test func aBundleSurvivesARoundTrip() throws {
        // A whole second: ISO-8601 carries no sub-second part, so `Date()` would fail
        // this on precision alone and say nothing about the encoding.
        let original = AccountBundle(exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     accounts: [Self.entry("a", email: "a@x.test")],
                                     policies: Policy.defaults,
                                     thresholds: AccountBundle.Thresholds(Settings()))
        #expect(try AccountBundle.decoded(from: original.encoded()) == original)
    }

    @Test func aBundleFromAnOlderBuildStillDecodes() throws {
        let json = #"{"version":1,"exportedAt":"2026-08-27T00:00:00Z","accounts":[{"id":"a"}]}"#
        let bundle = try AccountBundle.decoded(from: Data(json.utf8))
        #expect(bundle.accounts.first?.kind == .subscription)
        #expect(bundle.accounts.first?.inRotation == true)
        #expect(bundle.policies == nil)
    }

    // MARK: - Chrome profiles

    /// The guard that stands between a rewrite and losing Chrome's whole profile list.
    /// It compares against the key set as *read*, not as mutated — an earlier version
    /// passed the already-changed dictionary and so could never fail.
    @Test func aRewriteThatDropsProfilesIsRefused() throws {
        let original: Set<String> = ["Default", "Profile 1"]
        let intact = try JSONSerialization.data(withJSONObject:
            ["profile": ["info_cache": ["Default": ["name": "d"],
                                        "Profile 1": ["name": "one"]]]])
        #expect(ChromeProfileWriter.survivesRoundTrip(original: original, encoded: intact))

        let lost = try JSONSerialization.data(withJSONObject:
            ["profile": ["info_cache": ["Default": ["name": "d"]]]])
        #expect(!ChromeProfileWriter.survivesRoundTrip(original: original, encoded: lost))

        for broken in [Data("not json".utf8),
                       try JSONSerialization.data(withJSONObject: ["profile": [:]]),
                       try JSONSerialization.data(withJSONObject: [String: Any]())] {
            #expect(!ChromeProfileWriter.survivesRoundTrip(original: original,
                                                           encoded: broken))
        }
    }

    @Test func aNewProfileNeverStealsTheDefaultOne() {
        #expect(ChromeProfileWriter.nextFreeDirectory(existing: []) == "Profile 1")
        let taken = [ChromeProfile(directory: "Default", name: "d", email: nil),
                     ChromeProfile(directory: "Profile 1", name: "a", email: nil),
                     ChromeProfile(directory: "Profile 3", name: "c", email: nil)]
        #expect(ChromeProfileWriter.nextFreeDirectory(existing: taken) == "Profile 2")
    }

    /// Chrome writes a new profile into Local State only when it commits, so two sign-ins
    /// in quick succession would otherwise be sent to the same directory — and the second
    /// would open in a Chrome already signed in as the first account.
    @Test func aDirectoryHandedOutButNotYetOnDiskIsStillTaken() {
        let existing = [ChromeProfile(directory: "Default", name: "d", email: nil)]
        #expect(ChromeProfileWriter.nextFreeDirectory(existing: existing,
                                                      alsoTaken: ["Profile 1"])
                == "Profile 2")
        #expect(ChromeProfileWriter.nextFreeDirectory(
            existing: existing, alsoTaken: ["Profile 1", "Profile 2"]) == "Profile 3")
    }

    /// Chrome's own names are generic and mean nothing across machines. Matching one
    /// would drive the sign-in into the user's unrelated profile and record it there.
    @Test func genericChromeNamesAreNotIdentities() {
        for generic in ["Person 1", "person 12", "Default", "Profile 3", "Personne 2"] {
            #expect(ChromeProfileWriter.isGenericName(generic), "\(generic) should be generic")
        }
        for real in ["work", "acme corp", "Person Álvarez", "side project"] {
            #expect(!ChromeProfileWriter.isGenericName(real), "\(real) should not be generic")
        }
    }

    /// A hand-edited file can repeat an id; two rows with one identity make ForEach
    /// misrender.
    @Test func duplicateEntriesAreCollapsed() {
        let bundle = AccountBundle(accounts: [Self.entry("a"), Self.entry("a"),
                                              Self.entry("b")])
        #expect(AccountTransfer.plan(bundle, existing: []).steps.map(\.entry.id)
                == ["a", "b"])
    }
}

@Suite("Single instance")
struct SingleInstanceTests {
    /// The interlock that stops a second ccmux getting far enough to park every live
    /// session: a successful connect to the control socket is proof another instance
    /// owns the state, where LaunchServices has been observed to report nothing.
    @Test func aLiveSocketIsProofAndAStaleFileIsNot() throws {
        // The real socket, which the running app owns while these tests run, is not
        // touched — this exercises the same probe against a path of our own.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccmux-instance-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        // A file that nobody is listening on must not read as another instance.
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(!UnixSocketProbe.isLive(path: path))
        try? FileManager.default.removeItem(atPath: path)

        // Nothing there at all.
        #expect(!UnixSocketProbe.isLive(path: path))

        // Something actually accepting.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = try UnixSocket.address(for: path)
        _ = UnixSocket.withSockAddr(&addr) { p, l in bind(fd, p, l) }
        _ = listen(fd, 4)
        #expect(UnixSocketProbe.isLive(path: path))
    }
}

/// The probe `ControlServer` uses, reachable from a test without standing up a server.
enum UnixSocketProbe {
    static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = try? UnixSocket.address(for: path) else { return false }
        return UnixSocket.withSockAddr(&addr) { pointer, length in
            connect(fd, pointer, length) == 0
        }
    }
}
