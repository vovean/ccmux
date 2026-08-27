import CCMuxCore
import CCMuxKit
import Foundation
import Hummingbird
import HummingbirdTLS
import NIOCore
import NIOSSL
import Testing
@testable import CCMuxDaemonKit

/// The real `ServerClient` against a real ccmuxd over real TLS.
///
/// Everything else in the suite tests one side in isolation. This is the test that would
/// have caught the things isolation misses: a pin computed over the wrong bytes, an error
/// envelope the client cannot read, a path that is doubled by `appendingPathComponent`.
@Suite("End to end", .serialized)
struct EndToEndTests {
    /// A server on a kernel-assigned port, with a freshly minted self-signed certificate.
    private struct Harness {
        let client: ServerClient
        let fingerprint: String
        let baseURL: URL
        let password: String
    }

    private static let password = "test-password-with-a:colon"

    private static func certificate(in dir: URL) throws -> String {
        // Generated the same way scripts/install-ccmuxd.sh does, including the IP SAN,
        // so the test exercises the certificate shape that actually ships.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "2", "-nodes",
            "-keyout", dir.appendingPathComponent("key.pem").path,
            "-out", dir.appendingPathComponent("cert.pem").path,
            "-subj", "/CN=ccmuxd-test",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServerError.startup("openssl failed")
        }
        let der = try Data(contentsOf: dir.appendingPathComponent("cert.pem"))
        return CryptoShim.sha256Hex(try derBytes(fromPEM: der))
    }

    /// The pin is over the DER, which is what `SecCertificateCopyData` hands the client
    /// and what `openssl x509 -fingerprint -sha256` prints.
    private static func derBytes(fromPEM pem: Data) throws -> Data {
        let text = String(decoding: pem, as: UTF8.self)
        let body = text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let der = Data(base64Encoded: body) else {
            throw ServerError.startup("could not decode the PEM")
        }
        return der
    }

    private static func withServer(
        accounts: [RemoteAccount] = [],
        secrets: SecretStore = InMemorySecretStore(),
        transport: HTTPTransport = StubTransport(routes: [:]),
        _ body: @Sendable (Harness) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmuxd-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fingerprint = try certificate(in: dir)
        let accountsFile = dir.appendingPathComponent("accounts.json")
        if !accounts.isEmpty { JSONStore.save(accounts, to: accountsFile) }

        let registry = AccountRegistry(client: OAuthClient(transport: transport),
                                       secrets: secrets, accountsFile: accountsFile)
        await registry.bootstrap()
        let credential = BasicAuthCredential(
            username: "ccmux", passwordHashHex: CryptoShim.sha256Hex(Data(password.utf8)))

        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate
                .fromPEMFile(dir.appendingPathComponent("cert.pem").path)
                .map { NIOSSLCertificateSource.certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(
                file: dir.appendingPathComponent("key.pem").path, format: .pem)))
        tls.certificateVerification = .none

        // Port 0: the kernel picks, and onServerRunning reports what it picked. A fixed
        // port would make this test collide with whatever else is listening.
        let port = Locked<Int>(0)
        let ready = Locked<Bool>(false)
        let application = Application(
            router: Routes.build(registry: registry, credential: credential),
            server: try .tls(tlsConfiguration: tls),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                port.set(channel.localAddress?.port ?? 0)
                ready.set(true)
            })

        let running = Task { try await application.runService() }
        defer { running.cancel() }

        var waited = 0
        while !ready.get() && waited < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        try #require(ready.get(), "the server never came up")

        let baseURL = try #require(URL(string: "https://127.0.0.1:\(port.get())"))
        try await body(Harness(client: ServerClient(baseURL: baseURL, username: "ccmux",
                                                    password: password,
                                                    fingerprint: fingerprint),
                               fingerprint: fingerprint, baseURL: baseURL,
                               password: password))
    }

    @Test func theClientReachesTheServerOverPinnedTLS() async throws {
        try await Self.withServer { harness in
            let health = try await harness.client.health()
            #expect(health.apiVersion == ServerAPI.version)
            #expect(try await harness.client.accounts().isEmpty)
        }
    }

    /// The pin is the only thing standing between the client and any host answering on
    /// that address, because a self-signed certificate has no authority behind it.
    @Test func aCertificateThatDoesNotMatchThePinIsRefused() async throws {
        try await Self.withServer { harness in
            let wrong = ServerClient(baseURL: harness.baseURL, username: "ccmux",
                                     password: harness.password,
                                     fingerprint: String(repeating: "00", count: 32))
            await #expect(throws: (any Error).self) { try await wrong.health() }
        }
    }

    /// The probe deliberately trusts anything — it exists to *discover* the fingerprint —
    /// so it must agree with what the pin is later checked against.
    @Test func theProbeReportsTheFingerprintThePinUses() async throws {
        try await Self.withServer { harness in
            let probed = try await ServerClient.probeFingerprint(baseURL: harness.baseURL)
            #expect(probed == harness.fingerprint)
        }
    }

    @Test func aWrongPasswordIsReportedAsSuch() async throws {
        try await Self.withServer { harness in
            let wrong = ServerClient(baseURL: harness.baseURL, username: "ccmux",
                                     password: "not-it", fingerprint: harness.fingerprint)
            await #expect(throws: ServerClientError.unauthorized) { try await wrong.health() }
        }
    }

    /// A round trip through the real routes: adopt a key, then draw a token for it.
    ///
    /// This is also the regression test for double percent-encoding. The account id is a
    /// UUID, so it contains hyphens; escaping the component by hand before handing it to
    /// `appendingPathComponent` encoded the `%` a second time and every token request
    /// 404'd with `39220F76%252D23E7…`.
    @Test func anAPIKeyCanBeAdoptedAndThenDrawnDown() async throws {
        let transport = StubTransport(routes: ["/v1/models": (200, #"{"data":[]}"#)])
        try await Self.withServer(transport: transport) { harness in
            let adopted = try await harness.client.adopt(
                AdoptRequest(apiKey: "sk-ant-e2e", label: "End to end"))
            #expect(adopted.kind == .apiKey)
            #expect(adopted.apiKeyFingerprint == "sk-ant-e2e".apiKeyFingerprint)

            #expect(adopted.id.contains("-"), "the id must exercise path encoding")
            let grant = try await harness.client.grant(for: adopted.id)
            #expect(grant.apiKey == "sk-ant-e2e")
            #expect(grant.accessToken == nil)
        }
    }

    /// The message has to survive the trip. Hummingbird wraps it as
    /// `{"error":{"message":…}}`; a client decoding a flat string shows raw JSON instead.
    @Test func aServerErrorArrivesAsAReadableMessage() async throws {
        try await Self.withServer { harness in
            do {
                _ = try await harness.client.grant(for: "no-such-account")
                Issue.record("expected the request to fail")
            } catch let error as ServerClientError {
                let text = error.localizedDescription
                #expect(text.contains("no usable credential"))
                #expect(!text.contains("{"))
            }
        }
    }

    /// A whole login relay, minus the browser: the server issues the URL, keeps the
    /// verifier, and refuses the callback if the state does not match.
    @Test func theLoginRelayIssuesALoopbackRedirectAndChecksState() async throws {
        try await Self.withServer { harness in
            let started = try await harness.client.startLogin(
                LoginStartRequest(redirectPort: 51234))
            #expect(started.authorizeURL.contains("redirect_uri=http://localhost:51234/callback")
                    || started.authorizeURL.contains(
                        "redirect_uri=http%3A%2F%2Flocalhost%3A51234%2Fcallback"))
            #expect(!started.state.isEmpty)

            await #expect(throws: (any Error).self) {
                try await harness.client.finishLogin(
                    LoginFinishRequest(loginID: started.loginID, code: "x",
                                       state: "wrong-state"))
            }
        }
    }
}

/// Shared with the other suites' stub; duplicated locking rather than imported because
/// the client package's copy is test-internal there.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}
