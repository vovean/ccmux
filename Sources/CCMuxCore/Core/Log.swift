import Foundation

#if canImport(os)
import os
#endif

public enum Log {
    private static let queue = DispatchQueue(label: "io.vovean.ccmux.log")
    /// Building one of these per line costs ~56 us, which dominates a log write.
    private static let stamp = ISO8601DateFormatter()
    /// Queue-confined: the trim check stats the file, so it runs every N lines rather
    /// than on every line.
    private static var linesSinceTrimCheck = 0

    /// Queue-confined after `configure`. Nil until then, which is also what keeps the
    /// test suite out of the app's real log file — tests never configure a destination.
    private static var fileURL: URL?
    /// True on the server, where journald collects stdout and there is no os_log.
    private static var echoToStandardOutput = false

    // Immutable: `emit` reads this from whatever thread called it, so a var reassigned by
    // `configure` would be a genuine data race on a Swift static.
    #if canImport(os)
    private static let logger = Logger(subsystem: "io.vovean.ccmux", category: "ccmux")
    #endif

    /// Points logging at a file, and on the server at stdout. Call once at startup;
    /// lines emitted before it are not written to disk.
    public static func configure(fileURL url: URL?, echoToStandardOutput echo: Bool = false) {
        queue.sync {
            fileURL = url
            echoToStandardOutput = echo
        }
    }

    public static func info(_ message: String) { emit("INFO", message) }
    public static func warn(_ message: String) { emit("WARN", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        #if canImport(os)
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        #endif
        queue.async {
            let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
            if echoToStandardOutput {
                FileHandle.standardOutput.write(Data(line.utf8))
            }
            guard let path = fileURL?.path, let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
                linesSinceTrimCheck += 1
                if linesSinceTrimCheck >= 500 {
                    linesSinceTrimCheck = 0
                    trimIfNeeded(path: path)
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data,
                                              attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private static func trimIfNeeded(path: String) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
              size > 4_000_000 else { return }
        guard let all = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let tail = all.suffix(1_000_000)
        try? tail.write(to: URL(fileURLWithPath: path))
    }
}
