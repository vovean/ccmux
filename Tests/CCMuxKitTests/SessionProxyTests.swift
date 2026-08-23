import Foundation
import Testing
@testable import CCMuxKit

@Suite("Session proxy", .serialized)
struct SessionProxyTests {
    /// Issues one request against the proxy and returns the raw HTTP response bytes.
    static func request(port: UInt16, method: String = "POST", target: String = "/v1/messages",
                        body: String = "{}", authorization: String = "Bearer client-token",
                        extraHeaders: [String: String] = [:],
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

        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: \(authorization)\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(),
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
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try Self.request(port: port, authorization: "Bearer sk-ant-oat01-CLAUDES-OWN")
        let seen = try #require(stub.requests().first)
        #expect(seen.authorization == "Bearer token-a")
    }

    /// If ANTHROPIC_API_KEY is exported in the shell, Claude Code sends x-api-key
    /// alongside its bearer token — and that key could bill an account other than the
    /// one ccmux assigned.
    @Test func apiKeyHeaderIsNotForwarded() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try Self.request(port: port, extraHeaders: ["x-api-key": "sk-ant-api03-LEAK"])
        let seen = try #require(stub.requests().first)
        #expect(seen.authorization == "Bearer t")
        #expect(seen.apiKey == nil)
    }

    @Test func requestMethodPathAndBodyPassThroughUnchanged() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(), observer: { _ in })
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
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(), observer: { _ in })
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
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(),
                                 observer: { observations.append($0) })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.contains("anthropic-ratelimit-unified-5h-utilization: 0.42"))

        let seen = try #require(observations.all().first)
        #expect(seen.statusCode == 200)
        #expect(seen.accountID == "account-a")
        // Folded once here, so the parsers can index directly.
        #expect(seen.headers["anthropic-ratelimit-unified-5h-utilization"] == "0.42")
        #expect(seen.headers["content-type"] == nil)
        let windows = UsageParser.windowsFromResponseHeaders(seen.headers)
        #expect(windows.first?.percent == 42)
    }

    @Test func headRequestGetsNoBody() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "t"])
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(), observer: { _ in })
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
        let empty = TokenSequence([:])
        defer { withExtendedLifetime(empty) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: empty, relay: UpstreamRelay(), observer: { _ in })
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
        defer { withExtendedLifetime(tokens) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url,
                                 router: tokens, relay: UpstreamRelay(),
                                 observer: { observations.append($0) })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try Self.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 429"))
        let seen = try #require(observations.all().first)
        #expect(UsageParser.isRateLimited(headers: seen.headers, statusCode: seen.statusCode))
    }
}

/// Router stub: a fixed set of accounts, a selectable current one, and an optional
/// failover pool so the retry path can be driven.
final class TokenSequence: SessionRouting, @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String: String]
    private var selected: String
    /// Accounts the proxy is allowed to fail over to, in order.
    var failoverOrder: [String] = []
    /// What `soonestAvailability` should report.
    var soonest: Date?
    private(set) var failoverRequests: [Set<String>] = []

    init(_ tokens: [String: String]) {
        self.tokens = tokens
        selected = tokens.keys.sorted().first ?? ""
    }

    func select(_ accountID: String) {
        lock.lock(); selected = accountID; lock.unlock()
    }

    func assignment(sessionID: String) -> (accountID: String, token: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let token = tokens[selected] else { return nil }
        return (selected, token)
    }

    func failover(sessionID: String, model: String?, servedBy: String,
                  tried: Set<String>) -> (accountID: String, token: String)? {
        lock.lock(); defer { lock.unlock() }
        failoverRequests.append(tried)
        guard let next = failoverOrder.first(where: { !tried.contains($0) }),
              let token = tokens[next] else { return nil }
        selected = next
        return (next, token)
    }

    func soonestAvailability(model: String?) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return soonest
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

@Suite("Limit failover", .serialized)
struct FailoverTests {
    /// The point of the whole feature: a refusal reaches ccmux before Claude Code, so an
    /// account that still has headroom serves the same request and the session never
    /// learns there was a problem. Claude Code parking on a limit is what cost a night.
    @Test func aRefusalIsRetriedOnAnotherAccountAndNeverReachesTheClient() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        // The first account is refused; the second serves it.
        stub.responder = { request in
            request.authorization == "Bearer token-a"
                ? .init(status: "429 Too Many Requests",
                        headers: ["anthropic-ratelimit-unified-status": "rejected",
                                  "anthropic-ratelimit-unified-reset": "9999999999"],
                        chunks: ["refused"])
                : .init(status: "200 OK", headers: [:], chunks: ["served by b"])
        }

        let router = TokenSequence(["account-a": "token-a", "account-b": "token-b"])
        defer { withExtendedLifetime(router) {} }
        router.failoverOrder = ["account-b"]
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try SessionProxyTests.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("served by b"))
        // The client must not see the refusal at all, in status or body.
        #expect(!response.contains("429"))
        #expect(!response.contains("refused"))
        #expect(stub.requests().count == 2)
        #expect(stub.requests()[1].authorization == "Bearer token-b")
    }

    /// Each account is tried once. Cycling would also risk Claude Code's own
    /// "stopped after repeated usage-limit hits" guard.
    @Test func eachAccountIsTriedAtMostOnce() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        stub.responder = { _ in
            .init(status: "429 Too Many Requests",
                  headers: ["anthropic-ratelimit-unified-status": "rejected"],
                  chunks: ["refused"])
        }
        let router = TokenSequence(["a": "ta", "b": "tb", "c": "tc"])
        defer { withExtendedLifetime(router) {} }
        router.failoverOrder = ["b", "c"]
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try SessionProxyTests.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 429"))
        #expect(stub.requests().count == 3)
        #expect(Set(stub.requests().compactMap(\.authorization))
                == ["Bearer ta", "Bearer tb", "Bearer tc"])
    }

    /// When nothing can serve it, the refusal goes through — but describing the soonest
    /// moment *any* account frees up. Claude Code reads its automatic-continue time from
    /// this header and refuses to wait at all when it is more than 24h out, so a weekly
    /// reset from one account must not be what it sees when another frees up in hours.
    @Test func theResetHeaderDescribesTheSoonestAccount() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let weeklyReset = Date().addingTimeInterval(3 * 86400)
        stub.responder = { _ in
            .init(status: "429 Too Many Requests",
                  headers: ["anthropic-ratelimit-unified-status": "rejected",
                            "anthropic-ratelimit-unified-reset":
                                String(Int(weeklyReset.timeIntervalSince1970))],
                  chunks: ["refused"])
        }
        let soonest = Date().addingTimeInterval(4 * 3600)
        let router = TokenSequence(["a": "ta"])
        defer { withExtendedLifetime(router) {} }
        router.soonest = soonest
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try SessionProxyTests.request(port: port)
        #expect(response.hasPrefix("HTTP/1.1 429"))
        #expect(response.contains("anthropic-ratelimit-unified-reset: "
                                  + String(Int(soonest.timeIntervalSince1970))))
        #expect(!response.contains(String(Int(weeklyReset.timeIntervalSince1970))))
        // Exactly one reset header, or the client picks whichever it sees first.
        #expect(response.components(separatedBy: "anthropic-ratelimit-unified-reset")
                .count == 2)
    }

    /// A successful response must not pay for any of this.
    @Test func anOkResponseIsNotRetriedOrRewritten() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        stub.responder = { _ in
            .init(status: "200 OK",
                  headers: ["anthropic-ratelimit-unified-reset": "1787355000"],
                  chunks: ["fine"])
        }
        let router = TokenSequence(["a": "ta", "b": "tb"])
        defer { withExtendedLifetime(router) {} }
        router.failoverOrder = ["b"]
        router.soonest = Date().addingTimeInterval(60)
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let response = try SessionProxyTests.request(port: port)
        #expect(stub.requests().count == 1)
        #expect(response.contains("anthropic-ratelimit-unified-reset: 1787355000"))
        #expect(router.failoverRequests.isEmpty)
    }

    /// The model in the body decides which weekly window gates the request, so it has to
    /// reach the router.
    @Test func theRequestedModelIsPassedToTheRouter() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        stub.responder = { _ in
            .init(status: "429 Too Many Requests",
                  headers: ["anthropic-ratelimit-unified-status": "rejected"],
                  chunks: ["refused"])
        }
        let router = ModelRecordingRouter(token: "ta")
        defer { withExtendedLifetime(router) {} }
        let proxy = SessionProxy(sessionID: "test", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        _ = try SessionProxyTests.request(
            port: port, body: #"{"model":"claude-fable-5","max_tokens":16}"#)
        #expect(router.seenModels.contains("claude-fable-5"))
    }
}

final class ModelRecordingRouter: SessionRouting, @unchecked Sendable {
    private let lock = NSLock()
    private let token: String
    private var models: [String?] = []

    init(token: String) { self.token = token }

    var seenModels: [String] {
        lock.lock(); defer { lock.unlock() }
        return models.compactMap { $0 }
    }

    func assignment(sessionID: String) -> (accountID: String, token: String)? {
        ("a", token)
    }

    func failover(sessionID: String, model: String?, servedBy: String,
                  tried: Set<String>) -> (accountID: String, token: String)? {
        lock.lock(); models.append(model); lock.unlock()
        return nil
    }

    func soonestAvailability(model: String?) -> Date? {
        lock.lock(); models.append(model); lock.unlock()
        return nil
    }
}
