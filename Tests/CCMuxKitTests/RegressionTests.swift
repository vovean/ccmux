import Foundation
import Testing
@testable import CCMuxCore
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

/// Serialized: the stub protocol installs a process-wide responder, so two of these
/// running at once would each see the other's.
@Suite("Refresh coalescing", .serialized)
struct RefreshCoalescingTests {
    /// Look-up and insert used to be separate critical sections, so two callers could
    /// each see an empty slot and both POST the same refresh token *at the same time*.
    /// Anthropic rotates them, so the loser got `invalid_grant` and a healthy account was
    /// marked as needing re-login.
    ///
    /// Overlap is the property that matters, not the total count: grants that run one
    /// after another each rotate from the current token and are harmless.
    @Test func grantsNeverOverlapForOneAccount() async throws {
        let grants = ConcurrencyProbe()
        let vault = TokenVault(client: OAuthClient(transport: URLSessionTransport(session: StubURLProtocol.session {
            grants.enter()
            Thread.sleep(forTimeInterval: 0.2)
            grants.leave()
            return #"{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}"#
        })),
                               secrets: InMemorySecretStore())
        let id = "acct-overlap"
        vault.store(OAuthCredential(accessToken: "old", refreshToken: "r1",
                                    expiresAt: Date().addingTimeInterval(-60)), for: id)
        defer { vault.forget(id) }

        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await vault.refresh(id)?.accessToken }
            }
            for await result in group {
                // Every caller gets the rotated credential rather than nil.
                #expect(result == "rotated")
            }
        }
        #expect(grants.peak == 1)
        #expect(grants.total >= 1)
        #expect(vault.credential(for: id)?.refreshToken == "r2")
    }

    /// And the slot must be released, so a later refresh is still possible.
    @Test func aLaterRefreshIsNotBlockedByTheFinishedOne() async throws {
        let grants = ConcurrencyProbe()
        let vault = TokenVault(client: OAuthClient(transport: URLSessionTransport(session: StubURLProtocol.session {
            grants.enter()
            grants.leave()
            return #"{"access_token":"rotated","expires_in":28800}"#
        })),
                               secrets: InMemorySecretStore())
        let id = "acct-sequential"
        vault.store(OAuthCredential(accessToken: "old", refreshToken: "r1",
                                    expiresAt: Date().addingTimeInterval(-60)), for: id)
        defer { vault.forget(id) }

        _ = await vault.refresh(id)
        _ = await vault.refresh(id)
        #expect(grants.total == 2)
        #expect(grants.peak == 1)
    }
}

/// Records how many grants were ever in flight at once.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highWater = 0
    private var count = 0

    func enter() {
        lock.lock()
        current += 1
        count += 1
        highWater = max(highWater, current)
        lock.unlock()
    }

    func leave() {
        lock.lock(); current -= 1; lock.unlock()
    }

    var peak: Int {
        lock.lock(); defer { lock.unlock() }
        return highWater
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Serves a canned body for every request, so token-endpoint behaviour can be driven
/// without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responder: (() -> String)?
    private static let lock = NSLock()

    static func session(_ responder: @escaping () -> String) -> URLSession {
        lock.lock(); Self.responder = responder; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responder = Self.responder
        Self.lock.unlock()
        let body = responder?() ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
