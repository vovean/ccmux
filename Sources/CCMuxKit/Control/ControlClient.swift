import CCMuxCore
import Darwin
import Foundation

/// Client side of the control socket, used by the `ccmux` CLI.
public enum ControlClient {
    public static func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.failed("socket() failed") }
        defer { close(fd) }

        var addr = try UnixSocket.address(for: Paths.controlSocket.path)
        let connected = UnixSocket.withSockAddr(&addr) { pointer, length in
            connect(fd, pointer, length)
        }
        guard connected == 0 else {
            throw UnixSocketError.failed("ccmux is not running (connect errno \(errno))")
        }

        UnixSocket.suppressSIGPIPE(fd)
        // Must exceed the slowest server-side handler (importGlobalLogin waits up to
        // 60s), or the client gives up first and the server writes into a closed socket.
        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let payload = try JSONStore.encoder.encode(request)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw UnixSocketError.failed("could not encode request")
        }
        UnixSocket.writeLine(fd: fd, text.replacingOccurrences(of: "\n", with: " "))

        guard let line = UnixSocket.readLine(fd: fd), let data = line.data(using: .utf8) else {
            throw UnixSocketError.failed("no response from ccmux")
        }
        return try JSONStore.decoder.decode(ControlResponse.self, from: data)
    }

    public static var isRunning: Bool {
        (try? send(.ping)) != nil
    }

    /// Launches the app if it is not already up, then waits for the socket.
    public static func ensureRunning(timeout: TimeInterval = 20) throws {
        if isRunning { return }
        guard let app = appBundleURL() else {
            throw UnixSocketError.failed(
                "ccmux is not running and the app bundle could not be located")
        }
        // Launch through `open`, never by running the binary: Launch Services
        // registration is what makes notification authorization possible at all.
        Paths.writeHeadlessMarker()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g keeps the window from stealing focus from the terminal you just typed in.
        process.arguments = ["-g", app.path]
        try? process.run()
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning { return }
            usleep(200_000)
        }
        throw UnixSocketError.failed("ccmux did not come up within \(Int(timeout))s")
    }

    static func appBundleURL() -> URL? {
        // Running from inside the bundle (the normal case: ~/.local/bin/ccmux is a
        // symlink to Contents/MacOS/ccmux).
        var url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        for _ in 0..<3 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        for candidate in ["/Applications/ccmux.app",
                          "\(NSHomeDirectory())/Applications/ccmux.app"]
        where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
