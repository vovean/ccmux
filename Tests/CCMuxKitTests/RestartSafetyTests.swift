import Foundation
import Testing
@testable import CCMuxKit

@Suite("Restart safety", .serialized)
struct RestartSafetyTests {
    /// A session's port is baked into its ANTHROPIC_BASE_URL and cannot move, so it has
    /// to be one no other process is ever handed. macOS allocates outbound source ports
    /// from 49152–65535; anything below that is ours alone.
    @Test func proxyPortsAvoidTheEphemeralRange() {
        #expect(ProxyPorts.range.upperBound < 49152)
        #expect(ProxyPorts.candidates(avoiding: []).allSatisfy(ProxyPorts.isOurs))
    }

    @Test func portsInUseAreNotHandedOutTwice() {
        let taken: Set<UInt16> = [18000, 18001, 18003]
        let candidates = ProxyPorts.candidates(avoiding: taken, limit: 3)
        #expect(candidates == [18002, 18004, 18005])
    }

    /// The band is never exhausted in practice, and proving it by attempting a thousand
    /// binds would only delay the session that is waiting to start.
    @Test func theSearchIsBounded() {
        #expect(ProxyPorts.candidates(avoiding: [], limit: 8).count == 8)
        #expect(ProxyPorts.candidates(avoiding: Set(ProxyPorts.range)).isEmpty)
    }

    /// What a restart does: the same port, bound again by a new listener, serving the
    /// same session. Sessions can only survive a restart if this holds.
    ///
    /// It does not hold *immediately*: `NWListener.cancel()` is asynchronous, so a
    /// rebind attempted in the same breath gets EADDRINUSE. Across a real restart the
    /// port is released by process exit and is free at once — but this is the second
    /// reason `SessionManager.retryUnreachable` exists, and why a failed bind must
    /// never be treated as a dead session.
    @Test func aPortIsRebindableOnceItIsReleased() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        let tokens = TokenSequence(["a": "token-a"])
        defer { withExtendedLifetime(tokens) {} }

        let first = SessionProxy(sessionID: "restart", upstream: stub.url, router: tokens,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try first.start()
        first.stop()

        var second: SessionProxy?
        let rebound = Self.waitUntil {
            let attempt = SessionProxy(sessionID: "restart", desiredPort: port,
                                       upstream: stub.url, router: tokens,
                                       relay: UpstreamRelay(), observer: { _ in })
            guard (try? attempt.start()) == port else { return false }
            second = attempt
            return true
        }
        defer { second?.stop() }
        try #require(rebound)
        #expect(try SessionProxyTests.request(port: port).contains("200 OK"))
    }

    /// A shutdown that cancels the listener but leaves the sockets alone lets the turn
    /// in flight finish. Going straight to `stop()` severs the response mid-body, which
    /// the session sees as a failed turn.
    @Test func quiesceLetsTheRequestInFlightFinish() throws {
        let stub = try StubUpstream()
        defer { stub.stop() }
        // 20ms per chunk in the stub, so the response takes ~800ms to stream.
        stub.responseChunks = (0..<40).map { "chunk\($0) " }
        let tokens = TokenSequence(["a": "token-a"])
        defer { withExtendedLifetime(tokens) {} }

        let proxy = SessionProxy(sessionID: "drain", upstream: stub.url, router: tokens,
                                 relay: UpstreamRelay(), observer: { _ in })
        let port = try proxy.start()
        defer { proxy.stop() }

        let done = DispatchSemaphore(value: 0)
        let received = Locked("")
        DispatchQueue.global().async {
            received.set((try? SessionProxyTests.request(port: port)) ?? "")
            done.signal()
        }

        try #require(Self.waitUntil { proxy.activeRequests() == 1 })
        proxy.quiesce()
        // `NWListener.cancel()` is asynchronous, so the port keeps accepting for a
        // moment. That is harmless — a connection accepted in that window is counted by
        // `activeRequests` and the drain waits for it too — but it means the cutoff has
        // to be waited for rather than asserted on the next line.
        #expect(Self.waitUntil { !Self.canConnect(port: port) })

        #expect(done.wait(timeout: .now() + 10) == .success)
        let body = received.get()
        #expect(body.contains("200 OK"))
        #expect(body.contains("chunk0 "))
        #expect(body.contains("chunk39 "))
        #expect(proxy.activeRequests() == 0)
    }

    private static func waitUntil(_ condition: () -> Bool,
                                  timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return false
    }

    private static func canConnect(port: UInt16) -> Bool {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        return withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}

/// A box the test thread and the request thread can share without a data race.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}
