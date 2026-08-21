import Darwin
import Foundation

enum UnixSocketError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}

enum UnixSocket {
    /// sockaddr_un.sun_path is 104 bytes on Darwin, and a path that does not fit is
    /// silently truncated into a socket nobody can find.
    static let maxPathLength = 103

    /// Writing to a socket whose peer has gone raises SIGPIPE, whose default action is
    /// to terminate the process — which here would take down every live session's
    /// proxy because one CLI invocation timed out. Darwin has no MSG_NOSIGNAL, so the
    /// per-socket option is the only way to get EPIPE instead.
    static func suppressSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else {
            throw UnixSocketError.failed("socket path too long (\(bytes.count) bytes): \(path)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func withSockAddr<T>(_ addr: inout sockaddr_un,
                                _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func readLine(fd: Int32, limit: Int = 1 << 20) -> String? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            if let newline = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: chunk[0..<newline])
                break
            }
            data.append(contentsOf: chunk[0..<n])
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeLine(fd: Int32, _ text: String) {
        var payload = Data(text.utf8)
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
