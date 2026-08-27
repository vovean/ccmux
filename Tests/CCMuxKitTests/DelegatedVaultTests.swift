import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// Stands in for a ccmuxd. Records what was asked for so a test can prove the vault went
/// to the server rather than to Anthropic.
private final class StubRemote: RemoteTokenSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    private let grant: @Sendable (String) throws -> TokenGrant

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

    init(_ grant: @escaping @Sendable (String) throws -> TokenGrant) {
        self.grant = grant
    }

    func grant(for accountID: String) async throws -> TokenGrant {
        lock.lock(); _asked.append(accountID); lock.unlock()
        return try grant(accountID)
    }
}

/// A transport that fails the test if anything reaches it. A delegated account must never
/// run a refresh grant of its own.
private struct ForbiddenTransport: HTTPTransport {
    let onCall: @Sendable () -> Void
    func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply {
        onCall()
        return HTTPReply(status: 500, body: Data())
    }
}

/// A canned token response. Deliberately not `StubURLProtocol`: that registers a single
/// process-wide responder, so two suites using it run into each other's answers.
private struct CannedTransport: HTTPTransport {
    let body: String
    func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply {
        HTTPReply(status: 200, body: Data(body.utf8))
    }
}

@Suite("Delegated vault", .serialized)
struct DelegatedVaultTests {
    /// The failure this prevents: a delegated credential carries no refresh token, so a
    /// local refresh grant would come back `noRefreshToken`, and ccmux would report a
    /// perfectly healthy account as needing re-login.
    @Test func aDelegatedAccountRenewsFromTheServerNotByARefreshGrant() async throws {
        let upstreamCalls = Locked(0)
        let transport = ForbiddenTransport { upstreamCalls.set(upstreamCalls.get() + 1) }
        let remote = StubRemote { id in
            TokenGrant(accountID: id, kind: .subscription, accessToken: "from-server",
                       expiresIn: 3600, subscriptionType: "team")
        }
        let vault = TokenVault(client: OAuthClient(transport: transport),
                               secrets: InMemorySecretStore())
        vault.store(OAuthCredential(accessToken: "stale", refreshToken: nil,
                                    expiresAt: Date().addingTimeInterval(-60)),
                    for: "acct-1")
        vault.setRemote(remote, delegated: ["acct-1"])

        let renewed = await vault.refresh("acct-1")
        #expect(renewed?.accessToken == "from-server")
        #expect(remote.asked == ["acct-1"])
        #expect(upstreamCalls.get() == 0)
        // And what lands in the store still carries no refresh token, so this Mac cannot
        // rotate the lineage even by accident.
        #expect(vault.credential(for: "acct-1")?.refreshToken == nil)
        #expect(vault.credential(for: "acct-1")?.subscriptionType == "team")
    }

    /// Delegation is per account. One Mac can hold some accounts itself and pull others.
    @Test func anUndelegatedAccountStillRefreshesLocally() async throws {
        let remote = StubRemote { _ in
            Issue.record("the server was asked about an account that was never delegated")
            return TokenGrant(accountID: "x", kind: .subscription)
        }
        let transport = CannedTransport(
            body: #"{"access_token":"rotated-locally","expires_in":28800,"refresh_token":"r2"}"#)
        let vault = TokenVault(client: OAuthClient(transport: transport),
                               secrets: InMemorySecretStore())
        vault.store(OAuthCredential(accessToken: "old", refreshToken: "r1",
                                    expiresAt: Date().addingTimeInterval(-60)),
                    for: "mine")
        vault.setRemote(remote, delegated: ["someone-else"])

        let renewed = await vault.refresh("mine")
        #expect(renewed?.accessToken == "rotated-locally")
        #expect(remote.asked.isEmpty)
    }

    /// Disconnecting has to actually stop the delegation, or the vault would keep asking
    /// a server it is no longer configured for.
    @Test func clearingTheRemoteEndsDelegation() {
        let vault = TokenVault(client: OAuthClient(transport: ForbiddenTransport { }),
                               secrets: InMemorySecretStore())
        vault.setRemote(StubRemote { _ in TokenGrant(accountID: "a", kind: .subscription) },
                        delegated: ["a"])
        #expect(vault.isDelegated("a"))
        vault.setRemote(nil, delegated: ["a"])
        #expect(!vault.isDelegated("a"))
    }

    /// A server that cannot mint leaves the account alone rather than wiping what we hold.
    @Test func aServerFailureDoesNotDestroyTheCachedToken() async throws {
        let remote = StubRemote { _ in throw ServerClientError.unauthorized }
        let vault = TokenVault(client: OAuthClient(transport: ForbiddenTransport { }),
                               secrets: InMemorySecretStore())
        let cached = OAuthCredential(accessToken: "cached", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(1800))
        vault.store(cached, for: "acct-1")
        vault.setRemote(remote, delegated: ["acct-1"])

        #expect(await vault.refresh("acct-1") == nil)
        #expect(vault.credential(for: "acct-1")?.accessToken == "cached")
    }

    /// A grant carrying no access token is a malformed answer, not a reason to store an
    /// empty credential over a working one.
    @Test func aGrantWithNoTokenIsRejected() async throws {
        let remote = StubRemote { id in TokenGrant(accountID: id, kind: .subscription) }
        let vault = TokenVault(client: OAuthClient(transport: ForbiddenTransport { }),
                               secrets: InMemorySecretStore())
        vault.store(OAuthCredential(accessToken: "kept", refreshToken: nil,
                                    expiresAt: Date().addingTimeInterval(-1)),
                    for: "acct-1")
        vault.setRemote(remote, delegated: ["acct-1"])

        #expect(await vault.refresh("acct-1") == nil)
        #expect(vault.credential(for: "acct-1")?.accessToken == "kept")
    }

    /// `expiresIn` is seconds and is stamped against the local clock, so a server whose
    /// clock is off does not make the client think a dead token is live.
    @Test func expiryIsStampedAgainstTheLocalClock() {
        let grant = TokenGrant(accountID: "a", kind: .subscription, accessToken: "t",
                               expiresIn: 3600)
        let before = Date()
        let credential = grant.credential()
        let expiresAt = credential?.expiresAt ?? .distantPast
        #expect(expiresAt > before.addingTimeInterval(3500))
        #expect(expiresAt < before.addingTimeInterval(3700))
    }
}
