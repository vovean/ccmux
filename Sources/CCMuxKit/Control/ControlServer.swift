import CCMuxCore
import Darwin
import Foundation

/// Unix-socket command channel the `ccmux run` shim talks to.
///
/// A unix socket rather than a TCP port: the socket sits in a 0700 directory and the
/// peer's uid is checked, so nothing else on the machine can ask ccmux for a session
/// token.
public final class ControlServer {
    public typealias Handler = (ControlRequest) -> ControlResponse

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "io.vovean.ccmux.control", attributes: .concurrent)
    private let handler: Handler
    private var running = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() throws {
        try Paths.ensureSupportTree()
        let path = Paths.controlSocket.path

        // A socket file left behind by a crash would make bind() fail with EADDRINUSE
        // even though nothing is listening.
        if FileManager.default.fileExists(atPath: path), !isLive(path: path) {
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.failed("socket() failed") }
        var addr = try UnixSocket.address(for: path)
        let bound = UnixSocket.withSockAddr(&addr) { pointer, length in
            bind(fd, pointer, length)
        }
        guard bound == 0 else {
            close(fd)
            throw UnixSocketError.failed("bind(\(path)) failed (errno \(errno))")
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw UnixSocketError.failed("listen() failed (errno \(errno))")
        }
        listenFD = fd
        running = true
        Log.info("control socket listening at \(path)")

        queue.async { [self] in
            while running {
                let client = accept(listenFD, nil, nil)
                if client < 0 {
                    if running && errno != EINTR {
                        Log.warn("control accept failed (errno \(errno))")
                        usleep(100_000)
                    }
                    continue
                }
                queue.async { self.serve(client) }
            }
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            // shutdown() first: closing the descriptor while a thread is blocked in
            // accept() on it is undefined, whereas shutdown makes accept return.
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: Paths.controlSocket.path)
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.suppressSIGPIPE(fd)

        var peerUID = uid_t(0)
        var peerGID = gid_t(0)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            Log.warn("control connection rejected: peer uid mismatch")
            return
        }

        guard let line = UnixSocket.readLine(fd: fd),
              let data = line.data(using: .utf8) else { return }
        let response: ControlResponse
        if let request = try? JSONStore.decoder.decode(ControlRequest.self, from: data) {
            response = handler(request)
        } else {
            response = .failure("could not decode request")
        }
        if let encoded = try? JSONStore.encoder.encode(response),
           let text = String(data: encoded, encoding: .utf8) {
            UnixSocket.writeLine(fd: fd, text.replacingOccurrences(of: "\n", with: " "))
        }
    }

    /// Whether another ccmux already owns the control socket.
    ///
    /// A far stronger interlock than asking LaunchServices whether a second copy of the
    /// app is running: this is the resource that genuinely cannot be shared, and a
    /// successful connect is proof rather than a report. A stale file left by a crash
    /// accepts no connection and so does not count.
    public static func anotherInstanceIsRunning() -> Bool {
        isLive(path: Paths.controlSocket.path)
    }

    private func isLive(path: String) -> Bool { Self.isLive(path: path) }

    private static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = try? UnixSocket.address(for: path) else { return false }
        return UnixSocket.withSockAddr(&addr) { pointer, length in
            connect(fd, pointer, length) == 0
        }
    }
}
