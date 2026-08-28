import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// Drives the real `ServerClient` against a real, running ccmuxd.
///
/// The fixture suite pins the JSON shapes, but only this exercises the parts that live
/// between the two: TLS pinning against an actual certificate, the basic-auth header, URL
/// construction, HTTP/2 negotiation, and the client's own error mapping. ccmuxd is a
/// separate Go program, so none of that is covered by either language's compiler.
///
/// Opt-in, because it needs a server. `scripts/verify-server.sh` starts one and sets these:
///
///     CCMUXD_URL=https://127.0.0.1:28500 CCMUXD_PASSWORD=… CCMUXD_FINGERPRINT=… make test
@Suite("Live ccmuxd", .enabled(if: ProcessInfo.processInfo.environment["CCMUXD_URL"] != nil))
struct LiveServerTests {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static func baseURL() throws -> URL {
        let raw = try #require(env["CCMUXD_URL"])
        return try #require(URL(string: raw))
    }

    private static func client() throws -> ServerClient {
        let password = try #require(env["CCMUXD_PASSWORD"])
        let fingerprint = try #require(env["CCMUXD_FINGERPRINT"])
        return ServerClient(baseURL: try baseURL(),
                            username: env["CCMUXD_USERNAME"] ?? "ccmux",
                            password: password, fingerprint: fingerprint)
    }

    @Test func theProbeAgreesWithTheFingerprintWePin() async throws {
        let probed = try await ServerClient.probeFingerprint(baseURL: try Self.baseURL())
        // What install-ccmuxd.sh prints, lower-cased and unseparated.
        #expect(probed == (Self.env["CCMUXD_FINGERPRINT"] ?? "").lowercased())
    }

    @Test func healthNegotiatesAndDecodes() async throws {
        let health = try await Self.client().health()
        #expect(health.apiVersion == ServerAPI.version)
        #expect(health.uptimeSeconds >= 0)
    }

    @Test func accountsDecode() async throws {
        // Whatever the server holds, the envelope must decode and the version must match.
        _ = try await Self.client().accounts()
    }

    /// A certificate outside the pin must fail loudly rather than silently re-trusting.
    @Test func aWrongPinIsRefused() async throws {
        let wrong = ServerClient(baseURL: try Self.baseURL(), username: "ccmux",
                                 password: Self.env["CCMUXD_PASSWORD"] ?? "",
                                 fingerprint: String(repeating: "00", count: 32))
        await #expect(throws: (any Error).self) { try await wrong.health() }
    }

    @Test func aWrongPasswordIsReportedAsUnauthorized() async throws {
        let fingerprint = try #require(Self.env["CCMUXD_FINGERPRINT"])
        let wrong = ServerClient(baseURL: try Self.baseURL(), username: "ccmux",
                                 password: "not-it", fingerprint: fingerprint)
        await #expect(throws: ServerClientError.unauthorized) { try await wrong.health() }
    }

    /// The login relay, minus the browser. Proves the PKCE URL the Go server builds is the
    /// one the client's own loopback flow expects.
    @Test func theLoginRelayIssuesALoopbackRedirect() async throws {
        let started = try await Self.client().startLogin(
            LoginStartRequest(redirectPort: 51234))
        #expect(!started.loginID.isEmpty)
        #expect(!started.state.isEmpty)
        let url = try #require(URLComponents(string: started.authorizeURL))
        let items = Dictionary(uniqueKeysWithValues:
            (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["redirect_uri"] == "http://localhost:51234/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == started.state)
        #expect(items["client_id"] == OAuthClient.clientID)
    }

    /// A 404 from the token endpoint must reach the vault as a dead lineage, not as a
    /// network hiccup — that classification is what makes the account visibly broken and
    /// the sign-in-again button appear.
    @Test func anUnknownAccountIsReportedAsNoUsableCredential() async throws {
        await #expect(throws: RemoteTokenError.self) {
            _ = try await Self.client().grant(for: "definitely-not-an-account")
        }
    }

    /// And a genuine HTTP error still arrives as a readable message rather than raw JSON.
    @Test func serverErrorsAreReadable() async throws {
        do {
            _ = try await Self.client().usage(for: "definitely-not-an-account")
            Issue.record("expected the request to fail")
        } catch let error as ServerClientError {
            let text = error.localizedDescription
            #expect(text.contains("no usage recorded"))
            #expect(!text.contains("{"))
        }
    }
}
