import AppKit
import CCMuxCore
import Foundation

/// Opens a hook script in VS Code. Every step has a fallback, and the last one —
/// revealing the file in Finder — works on a Mac that has no VS Code at all.
public enum EditorOpener {
    public enum Outcome: Equatable {
        case opened
        /// VS Code is not installed, so the file was shown in Finder instead.
        case revealed
        case failed(String)

        public var message: String? {
            switch self {
            case .opened: return nil
            case .revealed: return "VS Code is not installed — showed the file in Finder."
            case .failed(let reason): return reason
            }
        }
    }

    /// Off the main actor: every attempt waits for a launcher to exit, and a cold VS Code
    /// takes seconds.
    @discardableResult
    public static func open(_ url: URL) async -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failed("\(url.lastPathComponent) is not on this Mac.")
        }
        let path = url.path
        let launched = await Task.detached(priority: .userInitiated) { () -> Bool in
            // The CLI first: it honours whichever build the user actually installed,
            // including VSCodium symlinked as `code`, and it reuses the open window
            // rather than launching a second one.
            if let cli = commandLineTool(), run(cli, [path]) { return true }
            return bundleIDs.contains { run("/usr/bin/open", ["-b", $0, path]) }
        }.value
        if launched { return .opened }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return .revealed
    }

    private static let bundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                                    "com.vscodium"]

    /// A GUI app inherits launchd's PATH, not the shell's, so `code` has to be looked for
    /// where the installers actually put it.
    private static func commandLineTool() -> String? {
        var candidates = ["/opt/homebrew/bin/code", "/usr/local/bin/code"]
        candidates.append(NSHomeDirectory() + "/.local/bin/code")
        for path in ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? [] {
            candidates.append(path + "/code")
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
