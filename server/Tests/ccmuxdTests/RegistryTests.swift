import CCMuxCore
import Foundation
import Testing
@testable import CCMuxDaemonKit

/// Canned upstream. Matches on the path so one stub can serve a profile call, a token
/// exchange and a usage fetch in the same test.
struct StubTransport: HTTPTransport {
    var routes: [String: (status: Int, body: String)]
    var onRequest: (@Sendable (HTTPRequestSpec) -> Void)?

    func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply {
        onRequest?(spec)
        let path = spec.url.path
        guard let route = routes.first(where: { path.hasSuffix($0.key) })?.value else {
            return HTTPReply(status: 404, body: Data(#"{"error":"no stub"}"#.utf8))
        }
        return HTTPReply(status: route.status, body: Data(route.body.utf8))
    }
}

private func makeRegistry(_ transport: StubTransport, secrets: SecretStore = InMemorySecretStore())
    -> (AccountRegistry, URL) {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("ccmuxd-test-\(UUID().uuidString).json")
    let registry = AccountRegistry(client: OAuthClient(transport: transport),
                                   secrets: secrets, accountsFile: file)
    return (registry, file)
}

private let profileJSON = """
{"account":{"uuid":"acct-1","email":"someone@example.com"},
 "organization":{"uuid":"org-1","name":"Example","organization_type":"claude_team",
                 "rate_limit_tier":"tier_x"}}
"""

@Suite("Registry")
struct RegistryTests {
    /// The invariant the entire client-server split rests on: a refresh token enters the
    /// server and never comes back out. Two holders of one lineage means the loser of the
    /// next rotation is told `invalid_grant` and is logged out for good.
    @Test func aTokenGrantNeverCarriesTheRefreshToken() async throws {
        let secrets = InMemorySecretStore()
        let (registry, file) = makeRegistry(
            StubTransport(routes: ["/api/oauth/profile": (200, profileJSON),
                                   "/api/oauth/usage": (200, "{}")]),
            secrets: secrets)
        defer { try? FileManager.default.removeItem(at: file) }

        let secret = "refresh-token-that-must-never-leave"
        let credential = OAuthCredential(accessToken: "access-1", refreshToken: secret,
                                         expiresAt: Date().addingTimeInterval(3600))
        _ = try await registry.adopt(AdoptRequest(credentialJSON: credential.jsonString()))

        let grant = try #require(await registry.token(for: "acct-1"))
        #expect(grant.accessToken == "access-1")

        // Checked on the encoded form, because that is what actually goes on the wire —
        // a future field could reintroduce the leak without changing `accessToken`.
        let wire = String(decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        #expect(!wire.contains(secret))

        // And it really is being held — the omission is deliberate, not an empty vault.
        let stored = try #require(try secrets.read("oauth:acct-1"))
        #expect(stored.contains(secret))
    }

    /// `expiresIn` is seconds rather than a timestamp: the server and a laptop do not
    /// agree on the wall clock, and a client trusting a remote absolute time would treat
    /// tokens as live that the API considers dead.
    @Test func tokenLifeIsReportedAsRemainingSeconds() async throws {
        let (registry, file) = makeRegistry(
            StubTransport(routes: ["/api/oauth/profile": (200, profileJSON),
                                   "/api/oauth/usage": (200, "{}")]))
        defer { try? FileManager.default.removeItem(at: file) }

        let credential = OAuthCredential(accessToken: "access-1", refreshToken: "r1",
                                         expiresAt: Date().addingTimeInterval(3600))
        _ = try await registry.adopt(AdoptRequest(credentialJSON: credential.jsonString()))
        let grant = try #require(await registry.token(for: "acct-1"))
        let life = try #require(grant.expiresIn)
        #expect(life > 3500 && life <= 3600)
    }

    /// A token close to expiry is refreshed before it is handed over, so a client that
    /// caches it does not immediately come back.
    @Test func anExpiringTokenIsRefreshedBeforeItIsHandedOver() async throws {
        let (registry, file) = makeRegistry(StubTransport(routes: [
            "/api/oauth/profile": (200, profileJSON),
            "/api/oauth/usage": (200, "{}"),
            "/v1/oauth/token": (200, #"{"access_token":"rotated","expires_in":28800,"refresh_token":"r2"}"#),
        ]))
        defer { try? FileManager.default.removeItem(at: file) }

        // Two minutes left: inside the ten-minute floor.
        let credential = OAuthCredential(accessToken: "nearly-dead", refreshToken: "r1",
                                         expiresAt: Date().addingTimeInterval(120))
        _ = try await registry.adopt(AdoptRequest(credentialJSON: credential.jsonString()))

        let grant = try #require(await registry.token(for: "acct-1"))
        #expect(grant.accessToken == "rotated")
        #expect(try #require(grant.expiresIn) > 28000)
    }

    /// A refresh that fails still yields the token we hold. Returning nil parks a live
    /// session for certain, whereas the API may honour the old token inside its grace
    /// period.
    @Test func aFailedRefreshStillReturnsTheTokenWeHave() async throws {
        let (registry, file) = makeRegistry(StubTransport(routes: [
            "/api/oauth/profile": (200, profileJSON),
            "/api/oauth/usage": (200, "{}"),
            "/v1/oauth/token": (503, "upstream is having a day"),
        ]))
        defer { try? FileManager.default.removeItem(at: file) }

        let credential = OAuthCredential(accessToken: "old-but-maybe-fine", refreshToken: "r1",
                                         expiresAt: Date().addingTimeInterval(60))
        _ = try await registry.adopt(AdoptRequest(credentialJSON: credential.jsonString()))
        let grant = try #require(await registry.token(for: "acct-1"))
        #expect(grant.accessToken == "old-but-maybe-fine")
    }

    /// An API-key account's id is a UUID generated by whichever Mac added it, so two
    /// machines holding the same key disagree about its id. Matching on the key's
    /// fingerprint is the only thing that stops the second Mac creating a duplicate.
    @Test func anAPIKeyIsMatchedByFingerprintNotByID() async throws {
        let (registry, file) = makeRegistry(
            StubTransport(routes: ["/v1/models": (200, #"{"data":[{"id":"claude-x"}]}"#)]))
        defer { try? FileManager.default.removeItem(at: file) }

        let first = try await registry.adopt(AdoptRequest(apiKey: "sk-ant-example",
                                                          label: "from mac one"))
        let second = try await registry.adopt(AdoptRequest(apiKey: "sk-ant-example",
                                                           label: "from mac two"))
        #expect(first.id == second.id)
        #expect(second.label == "from mac two")
        #expect(await registry.list().count == 1)
        #expect(first.apiKeyFingerprint == "sk-ant-example".apiKeyFingerprint)
    }

    @Test func aDifferentAPIKeyIsADifferentAccount() async throws {
        let (registry, file) = makeRegistry(
            StubTransport(routes: ["/v1/models": (200, #"{"data":[]}"#)]))
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await registry.adopt(AdoptRequest(apiKey: "sk-ant-one"))
        _ = try await registry.adopt(AdoptRequest(apiKey: "sk-ant-two"))
        #expect(await registry.list().count == 2)
    }

    /// The PKCE verifier stays on the server for the whole login, which is what makes the
    /// authorization code worthless to anyone who intercepts it on the way back.
    @Test func theAuthorizeURLRedirectsToTheClientsOwnLoopback() async throws {
        let (registry, file) = makeRegistry(StubTransport(routes: [:]))
        defer { try? FileManager.default.removeItem(at: file) }

        let started = await registry.startLogin(LoginStartRequest(redirectPort: 54321))
        let url = try #require(URLComponents(string: started.authorizeURL))
        let items = Dictionary(uniqueKeysWithValues:
            (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(items["redirect_uri"] == "http://localhost:54321/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == started.state)
        // The verifier is the secret; only its digest may appear in the URL.
        #expect(items["code_challenge"]?.isEmpty == false)
    }

    @Test func aLoginWithTheWrongStateIsRefused() async throws {
        let (registry, file) = makeRegistry(StubTransport(routes: [:]))
        defer { try? FileManager.default.removeItem(at: file) }

        let started = await registry.startLogin(LoginStartRequest(redirectPort: 1234))
        await #expect(throws: (any Error).self) {
            try await registry.finishLogin(LoginFinishRequest(loginID: started.loginID,
                                                              code: "abc",
                                                              state: "not-the-state"))
        }
    }

    @Test func anUnknownLoginIDIsRefused() async throws {
        let (registry, file) = makeRegistry(StubTransport(routes: [:]))
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: (any Error).self) {
            try await registry.finishLogin(LoginFinishRequest(loginID: "never-issued",
                                                              code: "abc"))
        }
    }

    /// An account in the file with no credential behind it must be visibly broken rather
    /// than 404-ing on every token request with nothing saying why.
    @Test func anAccountWithNoStoredCredentialIsMarkedNeedsRelogin() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmuxd-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        JSONStore.save([RemoteAccount(id: "orphan", label: "Orphan")], to: file)

        let registry = AccountRegistry(client: OAuthClient(transport: StubTransport(routes: [:])),
                                       secrets: InMemorySecretStore(), accountsFile: file)
        await registry.bootstrap()
        let account = try #require(await registry.list().first)
        #expect(account.health == .needsRelogin)
        #expect(await registry.token(for: "orphan") == nil)
    }

    @Test func removingAnAccountDropsItsSecret() async throws {
        let secrets = InMemorySecretStore()
        let (registry, file) = makeRegistry(
            StubTransport(routes: ["/v1/models": (200, #"{"data":[]}"#)]), secrets: secrets)
        defer { try? FileManager.default.removeItem(at: file) }

        let account = try await registry.adopt(AdoptRequest(apiKey: "sk-ant-gone"))
        #expect(try secrets.read("apikey:\(account.id)") != nil)
        try await registry.remove(account.id)
        #expect(try secrets.read("apikey:\(account.id)") == nil)
        #expect(await registry.list().isEmpty)
    }
}
