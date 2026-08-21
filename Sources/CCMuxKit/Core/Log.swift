import Foundation
import os

public enum Log {
    private static let queue = DispatchQueue(label: "io.vovean.ccmux.log")
    private static let logger = Logger(subsystem: Paths.bundleID, category: "ccmux")
    /// Building one of these per line costs ~56 us, which dominates a log write.
    private static let stamp = ISO8601DateFormatter()
    /// Queue-confined: the trim check stats the file, so it runs every N lines rather
    /// than on every line.
    private static var linesSinceTrimCheck = 0

    public static func info(_ message: String) { emit("INFO", message) }
    public static func warn(_ message: String) { emit("WARN", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        queue.async {
            let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = Paths.logFile.path
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
                linesSinceTrimCheck += 1
                if linesSinceTrimCheck >= 500 {
                    linesSinceTrimCheck = 0
                    Log.trimIfNeeded(path: path)
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
