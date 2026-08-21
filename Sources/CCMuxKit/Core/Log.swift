import Foundation
import os

public enum Log {
    private static let queue = DispatchQueue(label: "io.vovean.ccmux.log")
    private static let logger = Logger(subsystem: Paths.bundleID, category: "ccmux")

    public static func info(_ message: String) { emit("INFO", message) }
    public static func warn(_ message: String) { emit("WARN", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = Paths.logFile.path
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
                Log.trimIfNeeded(handle: handle, path: path)
            } else {
                FileManager.default.createFile(atPath: path, contents: data,
                                              attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private static func trimIfNeeded(handle: FileHandle, path: String) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
              size > 4_000_000 else { return }
        guard let all = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let tail = all.suffix(1_000_000)
        try? tail.write(to: URL(fileURLWithPath: path))
    }
}
