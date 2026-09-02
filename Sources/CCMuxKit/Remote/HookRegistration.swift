import CCMuxCore
import Foundation

/// Points Claude Code at the managed scripts the server has marked active, by editing the
/// `hooks` section of `~/.claude/settings.json`.
///
/// This is the one thing ccmux was built never to do, and it stays off until the user
/// turns it on: a background tick that can make a Mac start executing something new is a
/// different proposition from one that only writes inert files. What bounds it is
/// ownership — an entry is ccmux's only if its command resolves inside the managed
/// directory. Every other hook in the file, and every other key, is copied through
/// untouched.
public enum HookRegistration {
    /// The events a managed script can be registered under. The first path segment names
    /// one, so `UserPromptSubmit/fable-guidance.sh` registers as `UserPromptSubmit`.
    /// Unrecognised segments are ignored rather than written, since the value would land
    /// in a config Claude Code parses.
    public static let events: Set<String> = [
        "PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart", "SessionEnd",
        "Stop", "SubagentStop", "Notification", "PreCompact", "PostCompact",
        "PreModelSwitch", "PostModelSwitch", "WorktreeCreate", "WorktreeRemove",
        "InstructionsLoaded",
    ]

    public struct Change: Equatable, Sendable {
        public var registered: [String] = []
        public var unregistered: [String] = []
        public var isEmpty: Bool { registered.isEmpty && unregistered.isEmpty }
    }

    /// The event a script registers under, or nil when it cannot be registered at all —
    /// a helper at the root of the tree, or a directory that names no event.
    public static func event(for path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, let first = parts.first,
              events.contains(String(first)) else { return nil }
        return String(first)
    }

    /// Written with `$HOME` rather than an absolute path so the same file can be copied
    /// between Macs, which is how the user's own entries are already written.
    public static func command(for path: String) -> String {
        "$HOME/.claude/hooks/managed/\(path)"
    }

    /// True when this command is one ccmux owns. Both spellings appear in practice: the
    /// user writes `$HOME/...` by hand, and something else may have expanded it.
    static func isManaged(_ command: String, home: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for prefix in ["$HOME/.claude/hooks/managed/", "${HOME}/.claude/hooks/managed/",
                       "~/.claude/hooks/managed/", "\(home)/.claude/hooks/managed/"] {
            if trimmed.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Rewrites the `hooks` section so the managed entries are exactly `active`.
    ///
    /// Pure, so the file itself is only ever read and written once: the whole settings
    /// object goes in and comes back with unknown keys, unknown events and the user's own
    /// hooks in place.
    public static func apply(to settings: [String: Any], active: [String],
                             home: String) -> (settings: [String: Any], change: Change) {
        var change = Change()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var wanted: [String: [String]] = [:]
        for path in active.sorted() {
            guard let event = event(for: path) else { continue }
            wanted[event, default: []].append(command(for: path))
        }

        for event in Set(hooks.keys).union(wanted.keys) {
            let matchers = hooks[event] as? [[String: Any]] ?? []
            var kept: [[String: Any]] = []
            for matcher in matchers {
                let entries = matcher["hooks"] as? [[String: Any]] ?? []
                let survivors = entries.filter { entry in
                    guard let command = entry["command"] as? String,
                          isManaged(command, home: home) else { return true }
                    // Ours, and only kept if the server still says so. Comparing the
                    // command verbatim means an entry the user wrote by hand in the same
                    // form is adopted rather than duplicated.
                    if wanted[event]?.contains(command) == true { return true }
                    change.unregistered.append(command)
                    return false
                }
                if survivors.isEmpty, !entries.isEmpty { continue }
                var copy = matcher
                copy["hooks"] = survivors
                kept.append(copy)
            }

            let present = Set(kept.flatMap { ($0["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String } })
            for command in wanted[event] ?? [] where !present.contains(command) {
                kept.append(["hooks": [["type": "command", "command": command]]])
                change.registered.append(command)
            }

            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }

        var out = settings
        // Removed rather than left empty: an empty object is not what the file looked like
        // before ccmux touched it, and this has to be able to leave no trace.
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        change.registered.sort()
        change.unregistered.sort()
        return (out, change)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case write(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "could not read settings.json: \(why)"
            case .write(let why): return "could not write settings.json: \(why)"
            }
        }
    }

    /// Reads, rewrites and replaces the file, leaving it alone entirely when nothing
    /// changes.
    @discardableResult
    public static func reconcile(active: [String], settingsFile: URL,
                                 home: String = NSHomeDirectory()) throws -> Change {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsFile.path) {
            guard let data = try? Data(contentsOf: settingsFile) else {
                throw Failure.unreadable("unreadable")
            }
            // A settings.json that does not parse is the user's to fix. Overwriting it
            // with a fresh object would take every other setting with it.
            guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw Failure.unreadable("it is not a JSON object")
            }
            settings = object
        } else if active.isEmpty {
            return Change()
        }

        let result = apply(to: settings, active: active, home: home)
        guard !result.change.isEmpty else { return result.change }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: result.settings,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        let tmp = settingsFile.deletingLastPathComponent()
            .appendingPathComponent(".\(settingsFile.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: settingsFile.path) {
                _ = try fm.replaceItemAt(settingsFile, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: settingsFile)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.write(error.localizedDescription)
        }
        return result.change
    }
}
