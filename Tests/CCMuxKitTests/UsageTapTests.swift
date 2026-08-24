import Foundation
import Testing
@testable import CCMuxKit

@Suite("Streaming usage tap")
struct StreamingUsageTapTests {
    private func sse(_ lines: [String]) -> Data { Data(lines.joined().utf8) }

    @Test("Input comes from message_start, final output from the last message_delta")
    func readsAnSSEStream() {
        var tap = StreamingUsageTap()
        tap.consume(sse([
            "event: message_start\n",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"#,
            #""cache_read_input_tokens":800,"cache_creation":{"ephemeral_5m_input_tokens":300,"#,
            #""ephemeral_1h_input_tokens":50},"output_tokens":1}}}"# + "\n",
            "event: content_block_delta\n",
            #"data: {"type":"content_block_delta","delta":{"text":"hello"}}"# + "\n",
            #"data: {"type":"message_delta","usage":{"output_tokens":97}}"# + "\n",
        ]))
        tap.finish()

        let usage = tap.current
        #expect(usage.input == 1200)
        #expect(usage.cacheRead == 800)
        #expect(usage.cacheWrite5m == 300)
        #expect(usage.cacheWrite1h == 50)
        #expect(usage.output == 97, "the delta's count supersedes message_start's 1")
    }

    /// The proxy relays whatever chunk sizes the network hands it, so an event can be
    /// split anywhere — including mid-number.
    @Test("A stream split across arbitrary chunk boundaries reads the same")
    func survivesChunkSplits() {
        let whole = #"data: {"type":"message_delta","usage":{"output_tokens":4242}}"# + "\n"
        let bytes = Array(whole.utf8)
        for split in stride(from: 1, to: bytes.count, by: 7) {
            var tap = StreamingUsageTap()
            tap.consume(Data(bytes[0..<split]))
            tap.consume(Data(bytes[split...]))
            tap.finish()
            #expect(tap.current.output == 4242, "split at \(split)")
        }
    }

    @Test("A non-streaming body has no newline and is only readable at the end")
    func readsAPlainJSONBody() {
        var tap = StreamingUsageTap()
        tap.consume(Data(#"{"model":"x","usage":{"input_tokens":23,"output_tokens":4}}"#.utf8))
        #expect(tap.current.isEmpty, "nothing is parseable until the body ends")
        tap.finish()
        #expect(tap.current.input == 23)
        #expect(tap.current.output == 4)
    }

    @Test("A stream carrying no usage costs nothing")
    func ignoresUnrelatedEvents() {
        var tap = StreamingUsageTap()
        tap.consume(sse([
            #"data: {"type":"content_block_delta","delta":{"text":"usage of the word"}}"# + "\n",
            "event: ping\n",
        ]))
        tap.finish()
        #expect(tap.current.isEmpty)
    }

    @Test("The older cache shape without a 5m/1h split still bills")
    func legacyCacheShape() {
        var tap = StreamingUsageTap()
        tap.consume(Data(#"{"usage":{"input_tokens":5,"cache_creation_input_tokens":700}}"#.utf8))
        tap.finish()
        #expect(tap.current.cacheWrite5m == 700)
    }
}

@Suite("API-key rate limits")
struct APIWindowTests {
    @Test("The four families become windows with used-percent and a reset")
    func parsesHeaders() throws {
        let windows = UsageParser.apiWindowsFromResponseHeaders([
            "anthropic-ratelimit-requests-limit": "10000",
            "anthropic-ratelimit-requests-remaining": "9000",
            "anthropic-ratelimit-requests-reset": "2026-08-24T15:27:24Z",
            "anthropic-ratelimit-input-tokens-limit": "10000000",
            "anthropic-ratelimit-input-tokens-remaining": "7500000",
            "anthropic-ratelimit-input-tokens-reset": "2026-08-24T15:27:25Z",
        ])
        #expect(windows.count == 2)
        let requests = try #require(windows.first { $0.kind == .apiRequests })
        #expect(abs(requests.percent - 10) < 0.001)
        #expect(requests.resetsAt != nil)
        let input = try #require(windows.first { $0.kind == .apiInputTokens })
        #expect(abs(input.percent - 25) < 0.001)
    }

    /// These refill every minute, so they must never make an account look unusable.
    @Test("Per-minute ceilings never gate a request")
    func doNotGateRequests() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(kind: .apiRequests, label: "Requests/min", percent: 100),
            UsageWindow(kind: .apiInputTokens, label: "Input/min", percent: 100),
            UsageWindow(kind: .budget, label: "Budget", percent: 100),
        ])
        #expect(ModelRouting.bindingWindows(for: "claude-opus-5", in: snapshot).isEmpty)
        #expect(ModelRouting.canServe("claude-opus-5", usage: snapshot),
                "an exhausted per-minute window must not park a session")
    }

    @Test("Subscription headers and API headers do not read each other's shape")
    func shapesDoNotCrossOver() {
        let apiHeaders = ["anthropic-ratelimit-requests-limit": "100",
                          "anthropic-ratelimit-requests-remaining": "50"]
        #expect(UsageParser.windowsFromResponseHeaders(apiHeaders).isEmpty)
        let unified = ["anthropic-ratelimit-unified-5h-utilization": "0.5"]
        #expect(UsageParser.apiWindowsFromResponseHeaders(unified).isEmpty)
    }
}

/// A router that hands out whichever credential the test wants, so the proxy's header
/// rewriting can be checked on the wire rather than reasoned about.
final class FixedCredentialRouter: SessionRouting, @unchecked Sendable {
    private let assignmentValue: SessionAssignment
    init(_ credential: ProxyCredential, accountID: String = "acct") {
        assignmentValue = SessionAssignment(accountID: accountID, credential: credential)
    }
    func assignment(sessionID: String) -> SessionAssignment? { assignmentValue }
    func failover(sessionID: String, model: String?, servedBy: String,
                  tried: Set<String>) -> SessionAssignment? { nil }
    func soonestAvailability(model: String?, for sessionID: String) -> Date? { nil }
}

@Suite("Credential reaches the wire in the right header", .serialized)
struct CredentialSwapTests {
    private func seen(for credential: ProxyCredential) throws -> StubUpstream.Received {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let box = ReceivedBox()
        stub.responder = { received in
            box.set(received)
            return .init(status: "200 OK", headers: [:], chunks: ["{}"])
        }
        let router = FixedCredentialRouter(credential)
        defer { withExtendedLifetime(router) {} }
        let proxy = SessionProxy(sessionID: "t", upstream: stub.url, router: router,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }
        _ = try SessionProxyTests.request(port: port)
        return try #require(box.get())
    }

    @Test("An OAuth account sends Authorization and no x-api-key")
    func oauthShape() throws {
        let received = try seen(for: .oauth("tok-abc"))
        #expect(received.authorization == "Bearer tok-abc")
        #expect(received.apiKey == nil)
    }

    /// Sending both schemes is rejected upstream, and Claude Code always sends
    /// Authorization — so the unused one has to be cleared, not merely left alone.
    @Test("An API-key account sends x-api-key and clears Authorization")
    func apiKeyShape() throws {
        let received = try seen(for: .apiKey("sk-ant-api03-test"))
        #expect(received.apiKey == "sk-ant-api03-test")
        #expect(received.authorization == nil,
                "Claude Code's own bearer must not survive alongside the key")
    }
}

final class ReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: StubUpstream.Received?
    func set(_ v: StubUpstream.Received) { lock.lock(); value = v; lock.unlock() }
    func get() -> StubUpstream.Received? { lock.lock(); defer { lock.unlock() }; return value }
}
