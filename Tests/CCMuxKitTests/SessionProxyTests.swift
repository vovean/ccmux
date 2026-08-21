import Foundation
import Testing
@testable import CCMuxKit

@Suite("Session proxy", .serialized)
struct SessionProxyTests {
    /// Issues one request against the proxy and returns the raw HTTP response bytes.
    static func request(port: UInt16, method: String = "POST", target: String = "/v1/messages",
                        body: String = "{}", authorization: String = "Bearer client-token",
                        timeout: TimeInterval = 10) throws -> String {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let connected = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: \(authorization)\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = Array(head.utf8).withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }

        var response = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            response += String(decoding: buffer[0..<n], as: UTF8.self)
        }
        return response
    }

    /// The reason the proxy exists: Claude Code resolves its own token once at startup
    /// and never re-reads it, so switching a live session's account can only work if
    /// the token is chosen per request on the way out.
    @Test func tokenIsResolvedPerRequestSoASwitchTakesEffectImmediately() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }

        let tokens = TokenSequence(["account-a": "token-a", "account-b": "token-b"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() },
                                 observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try Self.request(port: port)
        tokens.select("account-b")
        _ = try Self.request(port: port)

        let seen = stub.requests()
        #expect(seen.count == 2)
        #expect(seen[0].authorization == "Bearer token-a")
        #expect(seen[1].authorization == "Bearer token-b")
    }

    /// Claude Code's own bearer token must never reach Anthropic: the whole point is
    /// that the session bills the account ccmux assigned, not the one Claude Code
    /// happens to be logged into.
    @Test func clientSuppliedAuthorizationIsReplaced() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["account-a": "token-a"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() }, observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try Self.request(port: port, authorization: "Bearer sk-ant-oat01-CLAUDES-OWN")
        let seen = try #require(stub.requests().first)
        #expect(seen.authorization == "Bearer token-a")
    }

    @Test func requestMethodPathAndBodyPassThroughUnchanged() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() }, observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try Self.request(port: port, method: "POST", target: "/v1/messages?beta=true",
                             body: #"{"model":"claude-opus-5"}"#)
        let seen = try #require(stub.requests().first)
        #expect(seen.method == "POST")
        #expect(seen.target == "/v1/messages?beta=true")
        #expect(seen.body == #"{"model":"claude-opus-5"}"#)
    }

    @Test func streamedResponseArrivesChunkedAndComplete() throws {
        let stub = try StubUpstream()
        stub.responseChunks = ["event: a\n", "data: one\n\n", "event: b\n", "data: two\n\n"]
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() }, observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Transfer-Encoding: chunked"))
        #expect(response.contains("Content-Type: text/event-stream"))
        #expect(!response.lowercased().contains("content-length:"))
        #expect(response.hasSuffix("0\r\n\r\n"))
        #expect(response.contains("data: one"))
        #expect(response.contains("data: two"))
    }

    /// The rate-limit headers on every response are how usage is tracked for free,
    /// without spending the usage endpoint's hourly budget.
    @Test func rateLimitHeadersAreObservedAndForwarded() throws {
        let stub = try StubUpstream()
        stub.responseHeaders = [
            "Content-Type": "application/json",
            "anthropic-ratelimit-unified-5h-utilization": "0.42",
            "anthropic-ratelimit-unified-status": "allowed",
        ]
        defer { stub.stop() }

        let observations = ObservationBox()
        let tokens = TokenSequence(["account-a": "token-a"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() },
                                 observer: { observations.append($0) })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.contains("anthropic-ratelimit-unified-5h-utilization: 0.42"))

        let seen = try #require(observations.all().first)
        #expect(seen.statusCode == 200)
        #expect(seen.accountID == "account-a")
        let windows = UsageParser.windowsFromResponseHeaders(seen.headers)
        #expect(windows.first?.percent == 42)
    }

    @Test func headRequestGetsNoBody() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() }, observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port, method: "HEAD", target: "/api/hello", body: "")
        #expect(response.contains("Content-Length: 0"))
        #expect(!response.contains("Transfer-Encoding: chunked"))
    }

    /// A session with no usable account must fail loudly rather than forwarding an
    /// unauthenticated request that would bill nobody and confuse Claude Code.
    @Test func missingAssignmentIsRefused() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { nil }, observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 503"))
        #expect(stub.requests().isEmpty)
    }

    @Test func upstreamStatusIsPreserved() throws {
        let stub = try StubUpstream()
        stub.statusLine = "429 Too Many Requests"
        stub.responseHeaders = ["anthropic-ratelimit-unified-status": "rejected"]
        defer { stub.stop() }

        let observations = ObservationBox()
        let tokens = TokenSequence(["a": "t"])
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 tokenProvider: { tokens.current() },
                                 observer: { observations.append($0) })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 429"))
        let seen = try #require(observations.all().first)
        #expect(UsageParser.isRateLimited(headers: seen.headers, statusCode: seen.statusCode))
    }
}

/// Mutable token source shared with the proxy's request queue.
final class TokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String: String]
    private var selected: String

    init(_ tokens: [String: String]) {
        self.tokens = tokens
        selected = tokens.keys.sorted().first ?? ""
    }

    func select(_ accountID: String) {
        lock.lock(); selected = accountID; lock.unlock()
    }

    func current() -> (accountID: String, token: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let token = tokens[selected] else { return nil }
        return (selected, token)
    }
}

final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SessionProxy.Observation] = []

    func append(_ item: SessionProxy.Observation) {
        lock.lock(); items.append(item); lock.unlock()
    }

    func all() -> [SessionProxy.Observation] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
