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
    }

    public override init() { super.init() }

    private let lock = NSLock()
    private var handlers: [Int: Handlers] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldUsePipelining = false
        config.timeoutIntervalForRequest = 0
        // Inference requests legitimately run for many minutes.
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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
        handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        task.cancel()
    }

    private func handlers(for task: URLSessionTask) -> Handlers? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
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
