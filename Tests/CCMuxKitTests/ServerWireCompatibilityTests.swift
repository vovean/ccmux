import Foundation
import Testing
@testable import CCMuxCore

/// The other half of the cross-language contract.
///
/// ccmuxd is Go and models this protocol independently, so nothing the compiler does can
/// catch a renamed key or a reformatted date — it would surface as a broken client on
/// someone's Mac. These fixtures are emitted by the server's own marshalling
/// (server/fixtures_test.go) and decoded here by the real types, through the real
/// `JSONStore.decoder` the client actually uses.
///
/// When the server changes shape: `UPDATE_FIXTURES=1 go test ./...` in server/, then make
/// sure this suite still passes.
@Suite("Server wire compatibility")
struct ServerWireCompatibilityTests {
    private static func fixture(_ name: String) throws -> Data {
        // #filePath is Tests/CCMuxKitTests/…; the fixtures live beside the Go server.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CCMuxKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("server/testdata/wire/\(name)")
        return try Data(contentsOf: url)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONStore.decoder.decode(type, from: try fixture(name))
    }

    @Test func healthDecodes() throws {
        let health = try Self.decode(HealthResponse.self, "health.json")
        #expect(health.apiVersion == ServerAPI.version)
        #expect(health.accounts == 2)
        #expect(health.uptimeSeconds == 1234.5)
    }

    @Test func theAccountListDecodes() throws {
        let response = try Self.decode(AccountListResponse.self, "accounts.json")
        #expect(response.apiVersion == ServerAPI.version)
        #expect(response.accounts.count == 2)

        let subscription = try #require(response.accounts.first)
        #expect(subscription.id == "11111111-2222-3333-4444-555555555555")
        #expect(subscription.label == "Work")
        #expect(subscription.email == "someone@example.com")
        #expect(subscription.organizationName == "Example Org")
        // The plan is what stops Claude Code treating a session as having no entitlements.
        #expect(subscription.subscriptionType == "team")
        #expect(subscription.rateLimitTier == "tier_x")
        #expect(subscription.kind == .subscription)
        #expect(subscription.health == .ok)

        let key = response.accounts[1]
        #expect(key.kind == .apiKey)
        #expect(key.health == .needsRelogin)
        #expect(key.healthDetail == "no credential on the server")
        // The only thing that can match a key account across two machines.
        #expect(key.apiKeyFingerprint == "sk-ant-fixture".apiKeyFingerprint)
    }

    @Test func aSubscriptionGrantDecodes() throws {
        let grant = try Self.decode(TokenGrant.self, "token-subscription.json")
        #expect(grant.kind == .subscription)
        #expect(grant.accessToken == "an-access-token")
        #expect(grant.expiresIn == 3599)
        #expect(grant.subscriptionType == "team")
        #expect(grant.scopes == ["user:inference", "user:profile"])
        #expect(grant.isUsable)
        // The invariant: nothing that could rotate a lineage comes back.
        #expect(grant.apiKey == nil)
    }

    @Test func anAPIKeyGrantDecodes() throws {
        let grant = try Self.decode(TokenGrant.self, "token-apikey.json")
        #expect(grant.kind == .apiKey)
        #expect(grant.apiKey == "sk-ant-fixture")
        #expect(grant.accessToken == nil)
        #expect(grant.isUsable)
    }

    /// A grant rebuilds into the credential shape the rest of ccmux speaks, and the expiry
    /// is stamped against *this* machine's clock rather than the server's.
    @Test func aGrantRebuildsIntoACredential() throws {
        let grant = try Self.decode(TokenGrant.self, "token-subscription.json")
        let before = Date()
        let credential = try #require(grant.credential())
        #expect(credential.accessToken == "an-access-token")
        #expect(credential.refreshToken == nil)
        #expect(credential.subscriptionType == "team")
        let expiresAt = try #require(credential.expiresAt)
        #expect(expiresAt > before.addingTimeInterval(3500))
        #expect(expiresAt < before.addingTimeInterval(3700))
    }

    /// The single most breakable thing in the interop. `JSONStore.decoder` uses `.iso8601`,
    /// which is ISO8601DateFormatter with only `.withInternetDateTime` — it rejects
    /// fractional seconds. Go's default marshalling would emit them, so the server carries
    /// a custom time type purely to keep this decoding.
    @Test func usageDecodesIncludingItsTimestamps() throws {
        let usage = try Self.decode(RemoteUsage.self, "usage.json")
        #expect(usage.accountID == "11111111-2222-3333-4444-555555555555")
        #expect(usage.ageSeconds == 42.5)
        #expect(usage.windows.count == 3)

        let session = usage.windows[0]
        #expect(session.kind == .session)
        #expect(session.percent == 33.5)
        let resets = try #require(session.resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: resets)
        #expect(parts.year == 2026 && parts.month == 8 && parts.day == 28)
        #expect(parts.hour == 15 && parts.minute == 4 && parts.second == 5)

        // A window with no reset must arrive as nil, not as a date in the year one.
        #expect(usage.windows[1].resetsAt == nil)

        let scoped = usage.windows[2]
        #expect(scoped.kind == .weeklyScoped)
        #expect(scoped.modelName == "Fable")
        #expect(scoped.percent == 61.25)
        // Ranking depends on this being right.
        #expect(scoped.headroom == 38.75)
    }

    @Test func theLoginStartResponseDecodes() throws {
        let started = try Self.decode(LoginStartResponse.self, "login-start.json")
        #expect(started.loginID == "a-login-id")
        #expect(started.state == "a-state-value")
        // The redirect stays on the client's own loopback — that is what makes the whole
        // relay work without Anthropic ever redirecting to the server.
        #expect(started.authorizeURL.contains("localhost%3A51234%2Fcallback"))
    }

    /// The client shows `error.message`; a flat `{"error":"..."}` decodes to nothing and
    /// the user is shown raw JSON instead.
    @Test func theErrorEnvelopeDecodes() throws {
        let envelope = try Self.decode(ServerErrorResponse.self, "error.json")
        #expect(envelope.message == "no usable credential for acct-1")
    }

    /// Every enum raw value the two sides must agree on, in one place.
    @Test func enumRawValuesAgree() {
        #expect(AccountKind.subscription.rawValue == "subscription")
        #expect(AccountKind.apiKey.rawValue == "apiKey")
        #expect(AccountHealth.ok.rawValue == "ok")
        #expect(AccountHealth.needsRelogin.rawValue == "needsRelogin")
        #expect(AccountHealth.unknown.rawValue == "unknown")
        #expect(UsageWindow.Kind.session.rawValue == "session")
        #expect(UsageWindow.Kind.weeklyAll.rawValue == "weeklyAll")
        #expect(UsageWindow.Kind.weeklyScoped.rawValue == "weeklyScoped")
        #expect(UsageWindow.Kind.other.rawValue == "other")
    }
}
