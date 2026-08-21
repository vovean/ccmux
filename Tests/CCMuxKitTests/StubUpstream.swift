import Darwin
import Foundation

/// A minimal loopback HTTP server standing in for api.anthropic.com, so the proxy can
/// be exercised end to end without touching the network.
final class StubUpstream: @unchecked Sendable {
    struct Received {
        var method: String
        var target: String
        var authorization: String?
        var body: String
    }

    private var sock: Int32 = -1
    private let lock = NSLock()
    private var received: [Received] = []
    private var stopped = false
    let port: UInt16

    /// Response body sent as several writes, so the proxy has to stream rather than
    /// wait for a complete body.
    var responseChunks: [String] = ["hello "]
    var responseHeaders: [String: String] = ["Content-Type": "text/event-stream"]
    var statusLine = "200 OK"

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw StubError.failed("socket") }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 8) == 0 else {
            close(s)
            throw StubError.failed("bind/listen")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(s, $0, &length)
            }
        }
        sock = s
        port = UInt16(bigEndian: local.sin_port)

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    enum StubError: Error { case failed(String) }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func requests() -> [Received] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = sock
        sock = -1
        lock.unlock()
        if s >= 0 { close(s) }
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let done = stopped; let s = sock; lock.unlock()
            if done || s < 0 { return }
            let client = accept(s, nil, nil)
            if client < 0 { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ fd: Int32) {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !text.contains("\r\n\r\n") {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return }
            text += String(decoding: buffer[0..<n], as: UTF8.self)
        }
        let headerEnd = text.range(of: "\r\n\r\n")!
        let head = String(text[text.startIndex..<headerEnd.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst().split(separator: " ").map(String.init)

        var authorization: String?
        var contentLength = 0
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if name == "authorization" { authorization = value }
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }

        var body = String(text[headerEnd.upperBound...])
        while body.utf8.count < contentLength {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            body += String(decoding: buffer[0..<n], as: UTF8.self)
        }

        lock.lock()
        received.append(Received(method: startLine.first ?? "", target: startLine.count > 1
                                 ? startLine[1] : "", authorization: authorization, body: body))
        let chunks = responseChunks
        let headers = responseHeaders
        let status = statusLine
        lock.unlock()

        let total = chunks.reduce(0) { $0 + $1.utf8.count }
        var head2 = "HTTP/1.1 \(status)\r\nContent-Length: \(total)\r\nConnection: close\r\n"
        for (name, value) in headers { head2 += "\(name): \(value)\r\n" }
        head2 += "\r\n"
        write(fd, head2)
        for chunk in chunks {
            write(fd, chunk)
            usleep(20_000)
        }
    }

    private func write(_ fd: Int32, _ text: String) {
        var data = Array(text.utf8)
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
            }
            if n <= 0 { return }
            sent += n
        }
    }
}
