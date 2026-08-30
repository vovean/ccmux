import CCMuxCore
import Foundation

public enum Paths {
    public static let bundleID = "io.vovean.ccmux"

    public static let support: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ccmux", isDirectory: true)
    }()

    public static var accountsFile: URL { support.appendingPathComponent("accounts.json") }
    public static var usageFile: URL { support.appendingPathComponent("usage.json") }
    public static var sessionsFile: URL { support.appendingPathComponent("sessions.json") }
    public static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public static var logFile: URL { support.appendingPathComponent("ccmux.log") }
    public static var notifiedFile: URL { support.appendingPathComponent("notified.json") }
    /// This Mac's identity on the account server. Kept out of settings.json so copying
    /// settings between Macs cannot give two of them the same machine id.
    public static var machineFile: URL { support.appendingPathComponent("machine.json") }
    /// Dropped by the shim before it launches the app, so a session started from a
    /// terminal does not pop a window over what you were doing.
    public static var headlessMarker: URL { support.appendingPathComponent(".headless") }
    public static var controlSocket: URL { support.appendingPathComponent("control.sock") }
    public static var namespaceRoot: URL { support.appendingPathComponent("ns", isDirectory: true) }

    public static func namespace(_ sid: String) -> URL {
        namespaceRoot.appendingPathComponent(sid, isDirectory: true)
    }

    public static var claudeHome: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    public static var claudeSessionsDir: URL {
        claudeHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// True once, then cleared: reading it is what consumes the shim's request.
    public static func consumeHeadlessMarker() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: headlessMarker.path) else { return false }
        try? fm.removeItem(at: headlessMarker)
        return true
    }

    public static func writeHeadlessMarker() {
        try? ensureSupportTree()
        FileManager.default.createFile(atPath: headlessMarker.path, contents: Data(),
                                      attributes: [.posixPermissions: 0o600])
    }

    /// Creates the support tree. 0700 throughout: it holds a control socket that
    /// grants token access to anything that can connect.
    public static func ensureSupportTree() throws {
        let fm = FileManager.default
        for dir in [support, namespaceRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
