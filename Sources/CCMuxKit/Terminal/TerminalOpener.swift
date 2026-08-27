import CCMuxCore
import AppKit
import Foundation

/// Brings a session's iTerm tab to the front.
public enum TerminalOpener {
    public enum Outcome: Equatable {
        case opened
        /// iTerm is running but has no tab matching this session any more.
        case notFound
        /// macOS refused the Apple event. Permission is per app signature, and ccmux is
        /// ad-hoc signed, so this comes back after a rebuild even once it was granted.
        case denied
        case noHandle
        case notRunning
        case gone
        case failed(String)

        public var message: String? {
            switch self {
            case .opened: return nil
            case .notFound:
                return "iTerm has no tab for this session any more."
            case .denied:
                return "macOS is blocking ccmux from controlling iTerm. Allow it under "
                    + "Privacy & Security → Automation."
            case .noHandle:
                return "This session does not say which terminal it is running in."
            case .notRunning:
                return "iTerm is not running."
            case .gone:
                return "That process is gone."
            case .failed(let reason):
                return "Could not reach iTerm: \(reason)"
            }
        }
    }

    static let bundleID = "com.googlecode.iterm2"

    public static func open(pid: Int32) -> Outcome {
        // A record can outlive its process by up to one reap, and a reused pid would
        // otherwise have its environment read and a stranger's tab brought forward.
        guard ClaudeSessions.isAlive(pid) else { return .gone }
        // `tell application "iTerm2"` launches iTerm if it is not running, which would
        // turn a misplaced press into a new empty window followed by "no tab for this
        // session".
        guard isITermRunning else { return .notRunning }

        let candidates = handles(for: pid)
        guard !candidates.isEmpty else { return .noHandle }
        var last = Outcome.notFound
        for handle in candidates {
            let outcome = attempt(handle)
            switch outcome {
            case .opened, .denied: return outcome
            default: last = outcome
            }
        }
        return last
    }

    private static func attempt(_ handle: TerminalLocator.Handle) -> Outcome {
        let result = run("/usr/bin/osascript", ["-e", TerminalLocator.script(for: handle)])
        guard result.code == 0 else {
            // -1743 is errAEEventNotPermitted: the user has not allowed ccmux to drive
            // iTerm, or the grant no longer matches this build's signature.
            if result.stderr.contains("-1743") || result.stderr.contains("not authorized")
                || result.stderr.contains("Not authorized") {
                return .denied
            }
            return .failed(result.stderr.isEmpty ? "exit \(result.code)" : result.stderr)
        }
        return result.stdout.contains("opened") ? .opened : .notFound
    }

    static func handles(for pid: Int32) -> [TerminalLocator.Handle] {
        let environment = run("/bin/ps", ["-Eww", "-p", "\(pid)"]).stdout
        let tty = run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalLocator.handles(environment: environment, tty: tty)
    }

    /// `static let` so the LaunchServices lookup happens once: the button asks per
    /// session card, on every republish of the session list.
    public static let isITermInstalled: Bool =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil

    static var isITermRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private struct Result {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    private static func run(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(code: -1, stdout: "", stderr: "\(error)")
        }
        // Drained before waiting: a full pipe buffer would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        // Bounded so a wedged helper cannot hold a thread for the life of the app. The
        // ceiling is generous because the consent dialog is answered by a human.
        if process.isRunning {
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            if process.isRunning, exited.wait(timeout: .now() + 180) == .timedOut {
                process.terminate()
                return Result(code: -1, stdout: "",
                              stderr: "\(path) did not answer")
            }
        }
        return Result(code: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
