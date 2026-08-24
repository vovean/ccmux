import Foundation
import Network

/// One loopback HTTP listener per Claude Code session.
///
/// Claude Code is pointed at it with ANTHROPIC_BASE_URL, so every inference request
/// passes through here. Two things happen on the way:
///
/// 1. `Authorization` is replaced with the token of whichever account the session is
///    assigned to *right now*, which is what makes mid-flight switching possible —
///    Claude Code resolves its own token once at startup and never re-reads it.
/// 2. `anthropic-ratelimit-unified-*` response headers are reported back, giving
///    exact live usage for free, without spending the usage endpoint's hourly budget.
///
/// One port per session rather than one shared port with a path prefix: session
/// identity is then the port, no path rewriting is needed on the way out, and the
/// base URL stays in the plain `scheme://host:port` form.
public final class SessionProxy {
    public struct Observation {
        public let statusCode: Int
        public let headers: [String: String]
        public let accountID: String
        /// What was asked for, so a block raised by one model is not cleared by another.
        public let model: String?
        /// Tokens billed for this request. Only present on the follow-up observation
        /// emitted once the body has finished streaming — the head arrives long before
        /// the counts do.
        public let usage: TokenUsage?

        public init(statusCode: Int, headers: [String: String], accountID: String,
                    model: String? = nil, usage: TokenUsage? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.accountID = accountID
            self.model = model
            self.usage = usage
        }
    }

    public static let defaultUpstream = URL(string: "https://api.anthropic.com")!

    public let sessionID: String
    /// Injectable so the proxy can be exercised against a local stub.
    private let upstream: URL
    fileprivate let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionHandler] = [:]

    /// Resolves who serves a request, and who could serve it if the assigned account
    /// refuses. Consulted per request, so a reassignment takes effect immediately.
    private weak var router: SessionRouting?
    private let observer: (Observation) -> Void
    /// Shared in production so sessions reuse one warm connection pool; injectable so a
    /// test can have its own and not contend with every other test in the process.
    private let relay: UpstreamRelay

    public private(set) var port: UInt16 = 0

    /// A specific port to re-bind, used when restoring a session that outlived the
    /// app: the port is baked into that session's ANTHROPIC_BASE_URL and cannot move.
    private let desiredPort: UInt16?

    public init(sessionID: String, desiredPort: UInt16? = nil,
                upstream: URL = SessionProxy.defaultUpstream,
                router: SessionRouting,
                relay: UpstreamRelay = .shared,
                observer: @escaping (Observation) -> Void) {
        self.sessionID = sessionID
        self.desiredPort = desiredPort
        self.upstream = upstream
        self.router = router
        self.relay = relay
        self.observer = observer
        self.queue = DispatchQueue(label: "io.vovean.ccmux.proxy.\(sessionID)")
    }

    /// Starts listening on 127.0.0.1 and returns the assigned port.
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        let wanted = desiredPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: wanted)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error), .waiting(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ProxyError.startFailed("listener did not become ready")
        }
        if let startError {
            listener.cancel()
            throw ProxyError.startFailed("\(startError)")
        }
        guard port != 0 else {
            listener.cancel()
            throw ProxyError.startFailed("no port assigned")
        }
        Log.info("proxy for session \(sessionID) listening on 127.0.0.1:\(port)")
        return port
    }

    public func stop() {
        queue.async { [self] in
            for handler in connections.values { handler.cancel() }
            connections.removeAll()
        }
        listener?.cancel()
        listener = nil
    }

    public enum ProxyError: Error, LocalizedError {
        case startFailed(String)

        public var errorDescription: String? {
            switch self {
            case .startFailed(let s): return "Could not start the session proxy: \(s)"
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection, proxy: self)
        connections[ObjectIdentifier(connection)] = handler
        handler.start()
    }

    fileprivate func forget(_ connection: NWConnection) {
        queue.async { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    /// Per-connection state. Every member is touched only from the proxy's serial
    /// queue, which is also where Network.framework delivers this connection's
    /// callbacks, so one request is served at a time — HTTP/1.1 has no way to
    /// interleave two responses on one socket.
    private final class ConnectionHandler {
        private let connection: NWConnection
        private weak var proxy: SessionProxy?
        private var parser = HTTPRequestParser()
        private var pending: [HTTPRequestParser.Request] = []
        private var busy = false
        private var peerClosed = false
        private var inFlight: URLSessionDataTask?

        init(connection: NWConnection, proxy: SessionProxy) {
            self.connection = connection
            self.proxy = proxy
        }

        func start() {
            guard let proxy else { return }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.teardown()
                default:
                    break
                }
            }
            connection.start(queue: proxy.queue)
            receive()
        }

        func cancel() {
            connection.cancel()
        }

        private func teardown() {
            if let inFlight {
                self.inFlight = nil
                proxy?.relay.cancel(inFlight)
            }
            proxy?.forget(connection)
        }

        private func finish() {
            connection.cancel()
            teardown()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.parser.append(data)
                    do {
                        while let request = try self.parser.next() {
                            self.pending.append(request)
                        }
                    } catch {
                        self.connection.send(
                            content: HTTPResponseWriter.error(status: 400, reason: "Bad Request",
                                                              message: "\(error)"),
                            completion: .contentProcessed { _ in self.finish() })
                        return
                    }
                    self.pump()
                }
                if isComplete || error != nil {
                    self.peerClosed = true
                    if !self.busy && self.pending.isEmpty { self.finish() }
                    return
                }
                self.receive()
            }
        }

        private func pump() {
            guard !busy, !pending.isEmpty, let proxy else { return }
            busy = true
            let request = pending.removeFirst()
            proxy.forward(request, on: connection,
                          onCancel: { [weak self] task in self?.inFlight = task }) {
                [weak self] keepAlive in
                guard let self, let proxy = self.proxy else { return }
                proxy.queue.async {
                    self.busy = false
                    self.inFlight = nil
                    // A queued request is served regardless; only an empty queue has to
                    // decide between waiting for more bytes and closing.
                    if !self.pending.isEmpty {
                        self.pump()
                    } else if !keepAlive || self.peerClosed {
                        self.finish()
                    }
                }
            }
        }
    }

    /// Request headers that describe our hop with Claude Code, not the upstream call.
    /// Accept-Encoding is dropped so URLSession picks its own and hands us a decoded
    /// body, which is what lets us re-frame the response as chunked.
    private static let strippedRequestHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        "accept-encoding", "authorization",
        // If ANTHROPIC_API_KEY is exported in the shell, Claude Code sends x-api-key
        // too — and that would bill an account other than the one assigned here.
        "x-api-key",
    ]

    fileprivate func forward(_ request: HTTPRequestParser.Request, on connection: NWConnection,
                             onCancel: @escaping (URLSessionDataTask) -> Void,
                             completion: @escaping (Bool) -> Void) {
        // The model decides which weekly window gates this request: a spent Fable week
        // does not stop an Opus call, and vice versa.
        let model = ModelRouting.model(inRequestBody: request.body)
        attempt(request, model: model, tried: [], on: connection, onCancel: onCancel,
                completion: completion)
    }

    /// Sends one upstream attempt, and on a limit refusal retries on another account
    /// before Claude Code ever sees it.
    ///
    /// This is what keeps a long run alive: the refusal arrives here first, so an account
    /// that still has headroom can serve the same request and Claude Code never learns
    /// there was a problem. Each account is tried at most once — cycling would also risk
    /// Claude Code's own "stopped after repeated usage-limit hits" guard.
    private func attempt(_ request: HTTPRequestParser.Request, model: String?,
                         tried: Set<String>,
                         resolved: SessionAssignment? = nil,
                         on connection: NWConnection,
                         onCancel: @escaping (URLSessionDataTask) -> Void,
                         completion: @escaping (Bool) -> Void) {
        let pending = PendingTask()
        guard let assignment = resolved ?? router?.assignment(sessionID: sessionID) else {
            connection.send(content: HTTPResponseWriter.error(
                status: 503, reason: "Service Unavailable",
                message: "ccmux has no account assigned to this session"),
                completion: .contentProcessed { _ in completion(false) })
            return
        }

        guard let url = URL(string: upstream.absoluteString + request.target) else {
            connection.send(content: HTTPResponseWriter.error(
                status: 400, reason: "Bad Request", message: "bad request target"),
                completion: .contentProcessed { _ in completion(false) })
            return
        }

        var outbound = URLRequest(url: url)
        outbound.httpMethod = request.method
        for (name, value) in request.headers
        where !Self.strippedRequestHeaders.contains(name.lowercased()) {
            outbound.addValue(value, forHTTPHeaderField: name)
        }
        // Sending both schemes is rejected upstream, and Claude Code always sends
        // Authorization — so whichever one is not in use has to be cleared, not just
        // left alone.
        switch assignment.credential {
        case .oauth(let token):
            outbound.setValue(nil, forHTTPHeaderField: "x-api-key")
            outbound.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key):
            outbound.setValue(nil, forHTTPHeaderField: "Authorization")
            outbound.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        if !request.body.isEmpty { outbound.httpBody = request.body }

        let keepAlive = request.wantsKeepAlive
        let isHeadRequest = request.method.caseInsensitiveCompare("HEAD") == .orderedSame
        let sessionID = self.sessionID
        var sentHead = false
        var bodyAllowed = true
        var tap = StreamingUsageTap()
        // Set when this attempt is being replaced; its remaining callbacks must not reach
        // the client, which is already being served by the retry.
        var abandoned = false

        let handlers = UpstreamRelay.Handlers(
            onHead: { [weak self] response in
                guard let self else { return }
                var headers: [(String, String)] = []
                var rateLimit: [String: String] = [:]
                for (rawName, rawValue) in response.allHeaderFields {
                    guard let name = rawName as? String,
                          let value = rawValue as? String else { continue }
                    headers.append((name, value))
                    // Folded once, and only the keys anything reads.
                    let folded = name.lowercased()
                    if folded.hasPrefix("anthropic-ratelimit-unified-") {
                        rateLimit[folded] = value
                    }
                }
                // Reported for every attempt: a refusal is still real usage news about
                // the account that produced it.
                self.observer(Observation(statusCode: response.statusCode,
                                          headers: rateLimit,
                                          accountID: assignment.accountID,
                                          model: model))

                if UsageParser.isRateLimited(headers: rateLimit,
                                             statusCode: response.statusCode) {
                    var attempted = tried
                    attempted.insert(assignment.accountID)
                    // Resolved once: `failover` reassigns the session as a side effect, so
                    // asking twice would rank twice and re-seed the namespace twice.
                    if let next = self.router?.failover(sessionID: sessionID, model: model,
                                                        servedBy: assignment.accountID,
                                                        tried: attempted) {
                        abandoned = true
                        // The replaced attempt is still streaming a refusal nobody will
                        // read; left alone it holds a connection until the 1h resource
                        // timeout.
                        pending.cancel()
                        Log.info("session \(sessionID): \(assignment.accountID) refused "
                                 + "\(model ?? "request"), retrying on \(next.accountID)")
                        self.queue.async {
                            self.attempt(request, model: model, tried: attempted,
                                         resolved: next, on: connection,
                                         onCancel: onCancel, completion: completion)
                        }
                        return
                    }
                    // Nothing can serve it. Claude Code decides whether to wait from
                    // `anthropic-ratelimit-unified-reset`, and refuses to wait at all when
                    // that is more than 24h out — so it has to describe the soonest moment
                    // *any* account frees up, not just this one's window.
                    if let soonest = self.router?.soonestAvailability(model: model, for: sessionID),
                       let shortened = Self.shorteningReset(headers, to: soonest) {
                        headers = shortened
                        Log.info("session \(sessionID): no account can serve "
                                 + "\(model ?? "request"); Claude Code told to retry at "
                                 + "\(Format.clock(soonest))")
                    }
                }

                bodyAllowed = !isHeadRequest && response.statusCode != 204
                    && response.statusCode != 304
                let framing = bodyAllowed
                    ? "Transfer-Encoding: chunked\r\n"
                    : "Content-Length: 0\r\n"
                let head = HTTPResponseWriter.head(
                    status: response.statusCode,
                    reason: HTTPResponseWriter.reasonPhrase(response.statusCode),
                    headers: headers,
                    framing: framing + (keepAlive ? "" : "Connection: close\r\n"))
                sentHead = true
                connection.send(content: head, completion: .contentProcessed { _ in })
            },
            onBody: { data in
                guard !abandoned, bodyAllowed, !data.isEmpty else { return }
                tap.consume(data)
                connection.send(content: HTTPResponseWriter.chunk(data),
                                completion: .contentProcessed { _ in })
            },
            onEnd: { error in
                guard !abandoned else { return }
                if let error {
                    Log.warn("proxy upstream error for session \(sessionID): \(error)")
                    if !sentHead {
                        connection.send(content: HTTPResponseWriter.error(
                            status: 502, reason: "Bad Gateway",
                            message: "upstream: \(error.localizedDescription)"),
                            completion: .contentProcessed { _ in completion(false) })
                        return
                    }
                    // The head is already on the wire and the status cannot be taken back.
                    // Dropping the connection without the terminating chunk is the only
                    // way to say "incomplete": sending it would hand Claude Code a
                    // syntactically complete response holding a truncated answer.
                    completion(false)
                    return
                }
                // The counts are only complete now, so they ride a second observation
                // rather than the one sent with the head.
                tap.finish()
                let billed = tap.current
                if !billed.isEmpty {
                    self.observer(Observation(statusCode: 200, headers: [:],
                                              accountID: assignment.accountID,
                                              model: model, usage: billed))
                }
                if bodyAllowed {
                    connection.send(content: HTTPResponseWriter.terminator,
                                    completion: .contentProcessed { _ in completion(keepAlive) })
                } else {
                    completion(keepAlive)
                }
            })

        let task = relay.send(outbound, handlers: handlers)
        pending.adopt(task, relay: relay)
        // Held so a client that disconnects mid-request does not leave the upstream leg
        // running against a one-hour resource timeout.
        onCancel(task)
    }

    /// Holds the in-flight task so a retry can cancel the attempt it replaces, even if
    /// the refusal arrives before `relay.send` has returned.
    private final class PendingTask {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var relay: UpstreamRelay?
        private var cancelled = false

        func adopt(_ task: URLSessionDataTask, relay: UpstreamRelay) {
            lock.lock()
            if cancelled {
                lock.unlock()
                relay.cancel(task)
                return
            }
            self.task = task
            self.relay = relay
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            let relay = self.relay
            self.task = nil
            lock.unlock()
            if let task, let relay { relay.cancel(task) }
        }
    }

    /// Brings the unified reset header forward to `date`, or returns nil to leave it
    /// alone. That header is where Claude Code reads the time it schedules its automatic
    /// continue from.
    ///
    /// Only ever shortens the wait. ccmux's view of a per-model weekly window can be
    /// stale — those windows never appear in response headers — and `availableAt` reports
    /// "now" when it sees nothing blocked. Writing that over a correct far-future reset
    /// would make Claude Code retry immediately, in a loop, burning a request on every
    /// account each time.
    static func shorteningReset(_ headers: [(String, String)], to date: Date,
                                now: Date = Date()) -> [(String, String)]? {
        let name = "anthropic-ratelimit-unified-reset"
        guard date.timeIntervalSince(now) > 30 else { return nil }
        let upstream = headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { Double($0.1) }
            .map { Date(timeIntervalSince1970: $0) }
        if let upstream, upstream <= date { return nil }
        var out = headers.filter { $0.0.caseInsensitiveCompare(name) != .orderedSame }
        out.append((name, String(Int(date.timeIntervalSince1970))))
        return out
    }
}
