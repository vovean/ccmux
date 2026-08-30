import CCMuxCore
import Foundation

public enum ServerClientError: Error, LocalizedError, Equatable {
    case unauthorized
    case certificateMismatch(expected: String, got: String)
    case http(Int, String)
    case transport(String)
    case decoding(String)
    case incompatible(Int)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The server rejected the username or password."
        case .certificateMismatch(let expected, let got):
            return "The server's certificate changed. Expected \(ServerFingerprint.short(expected))"
                + ", got \(ServerFingerprint.short(got)). Nothing was sent."
        case .http(let status, let message):
            return message.isEmpty ? "The server answered HTTP \(status)" : message
        case .transport(let message):
            return "Could not reach the server: \(message)"
        case .decoding(let message):
            return "The server's answer could not be read: \(message)"
        case .incompatible(let version):
            return "The server speaks API v\(version) and this ccmux speaks "
                + "v\(ServerAPI.version). Upgrade whichever is older."
        case .unsupported:
            return "This ccmuxd is too old for that — upgrade the server."
        }
    }
}

public enum ServerFingerprint {
    /// Grouped for reading aloud when confirming a server on first connect.
    public static func display(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(2, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: ":").uppercased()
    }

    public static func short(_ hex: String) -> String {
        String(display(hex).prefix(17)) + "…"
    }
}

/// Talks to a ccmuxd.
///
/// Two things it deliberately does not do: hold a refresh token, and trust a certificate
/// it has not been told to expect. The pin is checked on every request, not just the
/// first, so a swapped certificate fails loudly rather than silently re-trusting.
public final class ServerClient: NSObject, RemoteTokenSource, @unchecked Sendable {
    public let baseURL: URL
    private let username: String
    private let password: String
    private let pinnedFingerprint: String
    private let pin: PinnedTrust
    private let session: URLSession

    /// `proxy` follows the same rule as every other outbound path in ccmux: routing only
    /// some calls through it looks like the setting worked while the rest go direct, and
    /// on a machine that needs the proxy those are exactly the calls that fail.
    public init(baseURL: URL, username: String, password: String, fingerprint: String,
                proxy: UpstreamProxy? = nil, proxyPassword: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.pinnedFingerprint = fingerprint.lowercased()
        let pin = PinnedTrust(expected: fingerprint.lowercased(),
                              proxyCredential: ProxyTransport.credential(
                                  for: proxy, password: proxyPassword))
        self.pin = pin
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        ProxyTransport.apply(proxy, to: config)
        self.session = URLSession(configuration: config, delegate: pin, delegateQueue: nil)
        super.init()
    }

    /// A session holds its delegate until invalidated, so a discarded client would leak
    /// both. Clients are discarded routinely — every failed connect attempt makes one.
    deinit { session.invalidateAndCancel() }

    // MARK: - Trust on first use

    /// Completes a TLS handshake and reports the certificate's SHA-256, so the user can
    /// confirm it before anything is trusted.
    ///
    /// Sends no credentials — the whole point is that the peer is unverified at this
    /// moment, and a 401 back is a perfectly good outcome. Nothing here is written down;
    /// the caller stores the pin only after the user agrees to it.
    public static func probeFingerprint(baseURL: URL, proxy: UpstreamProxy? = nil,
                                        proxyPassword: String? = nil) async throws -> String {
        let collector = PinnedTrust(expected: nil,
                                    proxyCredential: ProxyTransport.credential(
                                        for: proxy, password: proxyPassword))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        ProxyTransport.apply(proxy, to: config)
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"
        _ = try? await session.data(for: request)
        guard let observed = collector.observed else {
            throw ServerClientError.transport(
                "no TLS handshake completed — is \(baseURL.absoluteString) a ccmuxd?")
        }
        return observed
    }

    // MARK: - Endpoints

    public func health() async throws -> HealthResponse {
        let response: HealthResponse = try await get(["health"])
        guard response.apiVersion == ServerAPI.version else {
            throw ServerClientError.incompatible(response.apiVersion)
        }
        return response
    }

    public func accounts() async throws -> [RemoteAccount] {
        let response: AccountListResponse = try await get(["accounts"])
        guard response.apiVersion == ServerAPI.version else {
            throw ServerClientError.incompatible(response.apiVersion)
        }
        return response.accounts
    }

    public func grant(for accountID: String) async throws -> TokenGrant {
        do {
            return try await get(["accounts", accountID, "token"])
        } catch ServerClientError.http(404, let message) {
            // Not a transient failure: the server is answering, and its answer is that it
            // cannot serve this account. Reported as such so the account is flagged and
            // the sign-in-again button appears.
            throw RemoteTokenError.noUsableCredential(message)
        }
    }

    public func usage(for accountID: String) async throws -> RemoteUsage {
        try await get(["accounts", accountID, "usage"])
    }

    public func startLogin(_ body: LoginStartRequest) async throws -> LoginStartResponse {
        try await post(["login", "start"], body)
    }

    public func finishLogin(_ body: LoginFinishRequest) async throws -> RemoteAccount {
        try await post(["login", "finish"], body)
    }

    public func adopt(_ body: AdoptRequest) async throws -> RemoteAccount {
        try await post(["accounts", "adopt"], body)
    }

    // MARK: - Sessions across machines

    /// Reports this Mac's whole session list and gets everyone's back — one round trip
    /// for both halves. The answer includes this machine; the caller drops its own id.
    public func reportSessions(machineID: String,
                               _ report: MachineReport) async throws -> SessionsResponse {
        try checkVersion(
            await unsupportedIfMissing {
                try await post(["machines", machineID, "sessions"], report)
            })
    }

    public func sessions() async throws -> SessionsResponse {
        try checkVersion(await unsupportedIfMissing { try await get(["sessions"]) })
    }

    /// Drops a machine's sessions. A 404 is success: either the server never had it, or
    /// this server predates the route — nothing is left behind either way.
    public func forgetMachine(_ machineID: String) async throws {
        do {
            try await delete(["machines", machineID])
        } catch {
            guard Self.isMissingRoute(error) else { throw error }
        }
    }

    /// Whether an error means the route is simply not on this server.
    ///
    /// A ccmuxd built before session sharing answers 404 for every one of those routes,
    /// and 405 for a path it knows under a different method. Both are facts about the
    /// server rather than failures worth showing the user as one.
    static func isMissingRoute(_ error: Error) -> Bool {
        switch error {
        case ServerClientError.http(404, _), ServerClientError.http(405, _): return true
        default: return false
        }
    }

    private func unsupportedIfMissing(
        _ body: () async throws -> SessionsResponse) async throws -> SessionsResponse {
        do {
            return try await body()
        } catch {
            throw Self.isMissingRoute(error) ? ServerClientError.unsupported : error
        }
    }

    private func checkVersion(_ response: SessionsResponse) throws -> SessionsResponse {
        guard response.apiVersion == ServerAPI.version else {
            throw ServerClientError.incompatible(response.apiVersion)
        }
        return response
    }

    // MARK: - Transport

    /// Built one component at a time and left to Foundation to encode. Escaping them by
    /// hand first meant `appendingPathComponent` encoded the `%` again, so an account id
    /// arrived as `39220F76%252D23E7…` and every token request 404'd.
    private func url(_ components: [String]) -> URL {
        components.reduce(baseURL.appendingPathComponent("v1")) {
            $0.appendingPathComponent($1)
        }
    }

    private func get<Response: Decodable>(_ path: [String]) async throws -> Response {
        try await send(request(path, method: "GET", body: nil))
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: [String],
                                                            _ body: Body) async throws
        -> Response {
        try await send(request(path, method: "POST",
                               body: try JSONStore.encoder.encode(body)))
    }

    private func delete(_ path: [String]) async throws {
        try await sendWithoutResponse(request(path, method: "DELETE", body: nil))
    }

    private func request(_ path: [String], method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        let basic = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await perform(request)
        do {
            return try JSONStore.decoder.decode(Response.self, from: data)
        } catch {
            throw ServerClientError.decoding("\(error)")
        }
    }

    private func sendWithoutResponse(_ request: URLRequest) async throws {
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A pin mismatch surfaces as a generic cancellation, so the specific cause is
            // reported from what the delegate saw rather than from the URLError.
            if let seen = pin.mismatch {
                throw ServerClientError.certificateMismatch(expected: pinnedFingerprint,
                                                            got: seen)
            }
            throw ServerClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ServerClientError.unauthorized }
        guard (200..<300).contains(status) else {
            let message = (try? JSONStore.decoder.decode(ServerErrorResponse.self,
                                                         from: data))?.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ServerClientError.http(status, message)
        }
        return data
    }
}

/// Certificate pinning. A self-signed certificate is the design's answer to serving both
/// an IP and a DNS name, which rules out a public CA — so the pin is the only thing
/// standing between the client and any host that answers on that address.
private final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expected: String?
    private let proxyCredential: URLCredential?
    private let lock = NSLock()
    private var _observed: String?
    private var _mismatch: String?

    var observed: String? { lock.lock(); defer { lock.unlock() }; return _observed }
    var mismatch: String? { lock.lock(); defer { lock.unlock() }; return _mismatch }

    /// `expected: nil` accepts any certificate and only records what it saw. That is the
    /// first-connect probe and nothing else — it never carries credentials.
    init(expected: String?, proxyCredential: URLCredential? = nil) {
        self.expected = expected
        self.proxyCredential = proxyCredential
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        // A proxy in front of us asks first, and with its own scheme. Answering that here
        // is not optional: the server-trust branch below would otherwise cancel it.
        if challenge.protectionSpace.isProxy() {
            let (disposition, credential) = ProxyTransport.respond(to: challenge,
                                                                   credential: proxyCredential)
            completionHandler(disposition, credential)
            return
        }
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = CryptoShim.sha256Hex(SecCertificateCopyData(leaf) as Data)
        lock.lock()
        _observed = fingerprint
        let expected = self.expected
        if let expected, expected != fingerprint { _mismatch = fingerprint }
        lock.unlock()

        guard let expected else {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if expected == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
