import Foundation
import Testing
@testable import CCMuxKit

@Suite("Single instance")
struct SingleInstanceTests {
    /// The interlock that stops a second ccmux getting far enough to park every live
    /// session: a successful connect to the control socket is proof another instance
    /// owns the state, where LaunchServices has been observed to report nothing.
    @Test func aLiveSocketIsProofAndAStaleFileIsNot() throws {
        // The real socket, which the running app owns while these tests run, is not
        // touched — this exercises the same probe against a path of our own.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccmux-instance-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        // A file that nobody is listening on must not read as another instance.
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(!UnixSocketProbe.isLive(path: path))
        try? FileManager.default.removeItem(atPath: path)

        // Nothing there at all.
        #expect(!UnixSocketProbe.isLive(path: path))

        // Something actually accepting.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = try UnixSocket.address(for: path)
        _ = UnixSocket.withSockAddr(&addr) { p, l in bind(fd, p, l) }
        _ = listen(fd, 4)
        #expect(UnixSocketProbe.isLive(path: path))
    }
}

/// The probe `ControlServer` uses, reachable from a test without standing up a server.
enum UnixSocketProbe {
    static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = try? UnixSocket.address(for: path) else { return false }
        return UnixSocket.withSockAddr(&addr) { pointer, length in
            connect(fd, pointer, length) == 0
        }
    }
}
