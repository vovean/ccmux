import Foundation

/// Streams one upstream request/response pair without buffering the body.
///
/// URLSession is used for the outbound leg so TLS, HTTP/2 and content decoding are
/// the system's problem, and a delegate (not `data(for:)`) so SSE frames reach the
/// client as they arrive instead of at completion.
public final class UpstreamRelay: NSObject, URLSessionDataDelegate {
    /// Shared across every session proxy: a per-proxy session would give each one its
    /// own connection pool and a cold TLS handshake per new session.
    public static let shared = UpstreamRelay()

    struct Handlers {
        let onHead: (HTTPURLResponse) -> Void
        let onBody: (Data) -> Void
        let onEnd: (Error?) -> Void
        /// Cancelling drops the handlers before URLSession reports completion, so `onEnd`
        /// never runs for a client that went away mid-stream. This fires instead, and is
        /// for bookkeeping only — the connection is already gone, so it must not write.
        var onCancelled: (() -> Void)?
    }

    public override init() { super.init() }

    private let lock = NSLock()
    private var handlers: [Int: Handlers] = [:]
    private var proxyCredential: URLCredential?
    private lazy var session: URLSession = Self.makeSession(proxy: nil, delegate: self)

    private static func makeSession(proxy: UpstreamProxy?,
                                    delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldUsePipelining = false
        config.timeoutIntervalForRequest = 0
        // Inference requests legitimately run for many minutes.
        config.timeoutIntervalForResource = 3600
        ProxyTransport.apply(proxy, to: config)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Rebuilds the session, because a URLSession's proxy is fixed at construction.
    /// In-flight requests keep the old session until they finish, which is why the old
    /// one is finished rather than invalidated: cancelling would abort live turns.
    public func setProxy(_ proxy: UpstreamProxy?, password: String?) {
        let credential = ProxyTransport.credential(for: proxy, password: password)
        lock.lock()
        proxyCredential = credential
        let old = session
        session = Self.makeSession(proxy: proxy, delegate: self)
        lock.unlock()
        old.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, handlers: Handlers) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        self.handlers[task.taskIdentifier] = handlers
        lock.unlock()
        task.resume()
        return task
    }

    /// Cancels one in-flight request. The shared session outlives any single proxy, so
    /// teardown cancels tasks rather than the session.
    func cancel(_ task: URLSessionDataTask) {
        lock.lock()
        let dropped = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        dropped?.onCancelled?()
        task.cancel()
    }

    private func handlers(for task: URLSessionTask) -> Handlers? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                         URLCredential?) -> Void) {
        lock.lock(); let credential = proxyCredential; lock.unlock()
        let (disposition, chosen) = ProxyTransport.respond(to: challenge,
                                                           credential: credential)
        completionHandler(disposition, chosen)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            handlers(for: dataTask)?.onHead(http)
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handlers(for: dataTask)?.onBody(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let found = handlers(for: task)
        lock.lock()
        handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        found?.onEnd(error)
    }
}
