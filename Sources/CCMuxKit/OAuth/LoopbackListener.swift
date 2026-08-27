import CCMuxCore
import Darwin
import Foundation

public enum LoopbackError: Error, LocalizedError {
    case socketFailed(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let s): return "Could not start the local sign-in listener: \(s)"
        case .timedOut: return "The browser never returned to ccmux."
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

/// Single-shot HTTP listener on 127.0.0.1 for the OAuth redirect. Bound to loopback
/// and to port 0, so the kernel picks the port that then goes into `redirect_uri`
/// (Claude Code's OAuth client accepts any loopback port).
public final class LoopbackListener: @unchecked Sendable {
    private var sock: Int32 = -1
    public let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    public init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw LoopbackError.socketFailed("socket() failed") }

        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(s)
            throw LoopbackError.socketFailed("bind() failed (errno \(errno))")
        }
        guard listen(s, 1) == 0 else {
            close(s)
            throw LoopbackError.socketFailed("listen() failed (errno \(errno))")
        }

        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        sock = s
        port = UInt16(bigEndian: local.sin_port)
    }

    /// Waits for the browser to hit `/callback` and returns its query items.
    public func awaitCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    continuation.resume(returning: try waitForCallback(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocks until the browser hits `/callback`. Prefer `awaitCallback`.
    func waitForCallback(timeout: TimeInterval) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { throw LoopbackError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw LoopbackError.timedOut }

            var descriptor = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 500)
            if ready < 0 {
                if errno == EINTR { continue }
                throw LoopbackError.socketFailed("poll() failed (errno \(errno))")
            }
            if ready == 0 { continue }

            let client = accept(sock, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw LoopbackError.socketFailed("accept() failed (errno \(errno))")
            }
            defer { close(client) }
            UnixSocket.suppressSIGPIPE(client)

            var request = ""
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains("\r\n\r\n") && request.utf8.count < 65536 {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { break }
                request += String(decoding: buffer[0..<n], as: UTF8.self)
            }
            guard let line = request.split(separator: "\r\n").first,
                  let target = line.split(separator: " ").dropFirst().first,
                  let url = URLComponents(string: "http://127.0.0.1\(target)")
            else {
                respond(client, status: "400 Bad Request", body: "bad request")
                continue
            }
            guard url.path == "/callback" else {
                respond(client, status: "404 Not Found", body: "not found")
                continue
            }
            var items: [String: String] = [:]
            for item in url.queryItems ?? [] { items[item.name] = item.value ?? "" }
            let ok = items["code"] != nil
            respond(client, status: ok ? "200 OK" : "400 Bad Request",
                    body: ok ? Self.successPage : "Sign-in failed. You can close this tab.")
            return items
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if sock >= 0 { close(sock); sock = -1 }
    }

    deinit { if sock >= 0 { close(sock) } }

    private func respond(_ fd: Int32, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        out.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }
    }

    private static let successPage = """
    <!doctype html><meta charset="utf-8"><title>ccmux</title>
    <body style="font:15px -apple-system,system-ui;padding:3rem;text-align:center">
    <h2>Signed in</h2><p>You can close this tab and go back to ccmux.</p>
    """
}
