import CCMuxCore
import AppKit
import Foundation

public enum OpenOutcome: Equatable, Sendable {
    case openedInProfile(String)
    case openedInDefaultBrowser
    case copiedToClipboard(reason: String)

    public var message: String {
        switch self {
        case .openedInProfile(let dir): return "Opened in Chrome profile “\(dir)”"
        case .openedInDefaultBrowser: return "Opened in the default browser"
        case .copiedToClipboard(let reason): return "\(reason) — link copied instead"
        }
    }

    /// Whether a browser actually came up. A clipboard fallback leaves the user waiting on
    /// a window that was never opened, so the caller has to be able to tell.
    public var opened: Bool {
        if case .copiedToClipboard = self { return false }
        return true
    }
}

public enum ChromeLauncher {
    private static let candidatePaths = [
        "/Applications/Google Chrome.app",
        "\(NSHomeDirectory())/Applications/Google Chrome.app",
        "/Applications/Google Chrome Beta.app",
        "/Applications/Google Chrome Canary.app",
    ]

    public static func chromeAppURL() -> URL? {
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static var isChromeInstalled: Bool { chromeAppURL() != nil }

    private static func executableURL(forApp app: URL) -> URL? {
        guard let bundle = Bundle(url: app), let exe = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: exe.path)
        else { return nil }
        return exe
    }

    /// Opens `url`, in a specific Chrome profile when one is given.
    ///
    /// Runs the Chrome binary directly rather than going through `open`: when Chrome
    /// is already running, the new process hands its command line (including
    /// `--profile-directory`) to the existing instance and exits. `open -a` drops the
    /// profile argument, which would land the login in whichever profile happens to
    /// be frontmost — the exact mistake this feature exists to prevent.
    @discardableResult
    public static func open(url: String, profileDirectory: String?) -> OpenOutcome {
        guard let profileDirectory, !profileDirectory.isEmpty else {
            if let target = URL(string: url) {
                NSWorkspace.shared.open(target)
                return .openedInDefaultBrowser
            }
            copy(url)
            return .copiedToClipboard(reason: "Not a valid URL")
        }
        guard let app = chromeAppURL(), let exe = executableURL(forApp: app) else {
            copy(url)
            return .copiedToClipboard(reason: "Google Chrome not found")
        }

        let process = Process()
        process.executableURL = exe
        process.arguments = ["--profile-directory=\(profileDirectory)", url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            copy(url)
            return .copiedToClipboard(
                reason: "Could not launch Chrome: \(error.localizedDescription)")
        }
        return .openedInProfile(profileDirectory)
    }

    public static func copy(_ url: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }
}
