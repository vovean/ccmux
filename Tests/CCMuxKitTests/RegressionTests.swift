import Foundation
import Testing
@testable import CCMuxKit

@Suite("Threshold crossings")
struct CrossingLogTests {
    /// The bug: a "re-arm" step ran before the claim and its prefix covered the current
    /// key, so every evaluation wiped the record and posted again — one notification per
    /// inference request once an account was below threshold.
    @Test func aCrossingIsAnnouncedOnce() {
        let log = CrossingLog(url: nil)
        let key = "acct/session/5-hour/1787355000"
        #expect(log.claim(key))
        #expect(!log.claim(key))
        #expect(!log.claim(key))
    }

    /// The reset time is part of the key, so a window that turns over re-arms without
    /// anything having to be cleared.
    @Test func aNewWindowPeriodAnnouncesAgain() {
        let log = CrossingLog(url: nil)
        #expect(log.claim("acct/session/5-hour/1787355000"))
        #expect(log.claim("acct/session/5-hour/1787373000"))
    }

    /// Pruning must drop the oldest, not an arbitrary half: evicting a live key
    /// re-announces a crossing the user already saw.
    @Test func pruningDropsTheOldestKeys() {
        let log = CrossingLog(url: nil)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<(CrossingLog.maxRecorded + 1) {
            #expect(log.claim("key-\(index)", now: base.addingTimeInterval(Double(index))))
        }
        #expect(log.count == CrossingLog.maxRecorded / 2)
        // The newest key survived; the oldest did not.
        #expect(!log.claim("key-\(CrossingLog.maxRecorded)"))
        #expect(log.claim("key-0"))
    }
}

@Suite("Persistence")
struct StoreTests {
    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func tableUpsertsMutatesAndRemoves() throws {
        let url = Self.scratch().appendingPathComponent("accounts.json")
        let table = Table<Account>(url: url)
        table.upsert(Account(id: "a", label: "first"))
        table.upsert(Account(id: "a", label: "second"))
        #expect(table.all().count == 1)
        #expect(table.get("a")?.label == "second")

        table.mutate("a") { $0.health = .needsRelogin }
        #expect(table.get("a")?.health == .needsRelogin)
        #expect(table.mutate("missing") { $0.label = "x" } == nil)

        // Reloading from disk must see the mutation, not just the upsert.
        #expect(Table<Account>(url: url).get("a")?.health == .needsRelogin)

        table.remove("a")
        #expect(table.all().isEmpty)
    }

    @Test func changesAreAnnouncedOnce() {
        let table = Table<Account>(url: Self.scratch().appendingPathComponent("a.json"))
        var changes = 0
        table.onChange = { changes += 1 }
        table.upsert(Account(id: "a", label: "a"))
        table.mutate("a") { $0.label = "b" }
        table.remove("a")
        #expect(changes == 3)
    }

    /// A fixed temp filename let two concurrent saves race on one path and lose a write.
    @Test func concurrentSavesToOneFileAllLand() throws {
        let url = Self.scratch().appendingPathComponent("usage.json")
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            JSONStore.save(["k\(index)": index], to: url)
        }
        let loaded = try #require(JSONStore.load([String: Int].self, from: url))
        #expect(loaded.count == 1)
    }
}

@Suite("Session records")
struct SessionRecordTests {
    /// Snapshotting the global setting at birth permanently opted out every session
    /// started while auto-switch was off, which reads as the feature being broken.
    @Test func autoSwitchFollowsTheGlobalSettingUnlessOverridden() {
        var record = SessionRecord(id: "s", pid: 1, port: 1, accountID: "a",
                                   policyName: "opus", cwd: "/tmp")
        #expect(record.autoSwitchEnabled(default: true))
        #expect(!record.autoSwitchEnabled(default: false))

        record.autoSwitchOverride = false
        #expect(!record.autoSwitchEnabled(default: true))
        record.autoSwitchOverride = true
        #expect(record.autoSwitchEnabled(default: false))
    }
}

@Suite("Settings mutation")
struct SettingsMutationTests {
    @Test func watchedWindowsCannotAccumulateDuplicates() {
        var settings = Settings()
        settings.setWatched(.session, on: true)
        settings.setWatched(.session, on: true)
        #expect(settings.watchedWindows.filter { $0 == .session }.count == 1)

        settings.setWatched(.session, on: false)
        #expect(!settings.watchedWindows.contains(.session))
        settings.setWatched(.session, on: false)
        #expect(!settings.watchedWindows.contains(.session))
    }
}

@Suite("OAuth error classification")
struct OAuthErrorTests {
    /// The 429 backoff used to be recovered by substring-matching a formatted message,
    /// so rewording that message would silently disable it.
    @Test func statusCodeIsCarriedNotReparsed() {
        #expect(OAuthError.transient("HTTP 429: slow down", status: 429).statusCode == 429)
        #expect(OAuthError.transient("network: offline").statusCode == nil)
        #expect(OAuthError.invalidGrant("dead").statusCode == nil)
    }

    @Test func onlyGrantRejectionIsPermanent() {
        #expect(OAuthError.invalidGrant("x").isPermanent)
        #expect(OAuthError.noRefreshToken.isPermanent)
        #expect(!OAuthError.transient("x", status: 429).isPermanent)
        #expect(!OAuthError.badResponse("x").isPermanent)
    }
}

@Suite("Credential namespace hygiene")
struct NamespaceTests {
    /// Two sessions on one account get two namespaces, and their Keychain items must be
    /// distinct or one would read the other's credential.
    @Test func eachSessionNamespaceGetsItsOwnKeychainItem() {
        let first = ClaudeCredentialStore.service(
            forNamespace: URL(fileURLWithPath: "/tmp/ns/session-one"))
        let second = ClaudeCredentialStore.service(
            forNamespace: URL(fileURLWithPath: "/tmp/ns/session-two"))
        #expect(first != second)
        #expect(first.hasPrefix("Claude Code-credentials-"))
        #expect(second.hasPrefix("Claude Code-credentials-"))
    }

    /// Unicode normalization matters: Claude Code hashes the NFC form, so a decomposed
    /// path must resolve to the same item or the session would read as logged out.
    @Test func serviceNameIsNormalizationStable() {
        let composed = ClaudeCredentialStore.service(
            forNamespace: URL(fileURLWithPath: "/tmp/caf\u{00E9}"))
        let decomposed = ClaudeCredentialStore.service(
            forNamespace: URL(fileURLWithPath: "/tmp/cafe\u{0301}"))
        #expect(composed == decomposed)
    }
}
