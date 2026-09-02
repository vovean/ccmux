import CCMuxCore
import Foundation

/// Points Claude Code at the managed scripts the server has marked active, by editing the
/// `hooks` section of `~/.claude/settings.json`.
///
/// This is the one thing ccmux was built never to do, and it stays off until the user
/// turns it on: a background tick that can make a Mac start executing something new is a
/// different proposition from one that only writes inert files.
///
/// What bounds it is an exact match. An entry is ccmux's only when its command is
/// character-for-character one this would write, for a script the server actually holds,
/// under that script's own event. Anything else that merely lives in the managed
/// directory — the same script with an argument, a helper registered by hand — is the
/// user's, and is copied through with every other hook and key in the file.
public enum HookRegistration {
    /// The events a managed script can be registered under. The first path segment names
    /// one, so `UserPromptSubmit/fable-guidance.sh` registers as `UserPromptSubmit`.
    public static let events: Set<String> = [
        "PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart", "SessionEnd",
        "Stop", "SubagentStop", "Notification", "PreCompact", "PostCompact",
        "PreModelSwitch", "PostModelSwitch", "WorktreeCreate", "WorktreeRemove",
        "InstructionsLoaded",
    ]

    public struct Change: Equatable, Sendable {
        public var registered: [String] = []
        public var unregistered: [String] = []
        /// Active scripts that no event directory claims, so nothing was written for
        /// them. Reported rather than dropped: silence here reads identically to a
        /// working hook.
        public var unregisterable: [String] = []
        public var isEmpty: Bool { registered.isEmpty && unregistered.isEmpty }
    }

    /// The event a script registers under, or nil for a helper at the root of the tree or
    /// a directory naming no event.
    public static func event(for path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, let first = parts.first,
              events.contains(String(first)) else { return nil }
        return String(first)
    }

    /// Written with `$HOME` so the same file can be copied between Macs, which is how the
    /// user's own entries are already written.
    public static func command(for path: String) -> String {
        "$HOME/.claude/hooks/managed/\(path)"
    }

    /// One spelling for the four that occur, so an entry written `~/…` or with the home
    /// directory spelled out is recognised as the same command rather than duplicated.
    /// Anything trailing the path — an argument, a redirect — survives and makes the
    /// command unequal, which is what keeps it out of ccmux's hands.
    static func canonical(_ command: String, home: String) -> String {
        var text = command.trimmingCharacters(in: .whitespaces)
        for prefix in ["$HOME/", "${HOME}/", "~/", home + "/"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text
    }

    /// Rewrites the `hooks` section so the entries ccmux owns are exactly `active`.
    ///
    /// `known` is every script the server holds. It is what makes withdrawing one work:
    /// a command is only ever removed when it names a script in that set, so an entry
    /// pointing at something ccmux never published is left where it is.
    public static func apply(to settings: [String: Any], known: [String],
                             active: [String],
                             home: String) -> (settings: [String: Any], change: Change) {
        var change = Change()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // event -> canonical command -> path, for scripts this could have written.
        var owned: [String: [String: String]] = [:]
        for path in known {
            guard let event = event(for: path) else { continue }
            owned[event, default: [:]][canonical(command(for: path), home: home)] = path
        }
        var wanted: [String: [String]] = [:]
        for path in active.sorted() {
            guard let event = event(for: path) else {
                change.unregisterable.append(path)
                continue
            }
            wanted[event, default: []].append(path)
        }

        for event in Set(hooks.keys).union(wanted.keys).sorted() {
            var matchers: [[String: Any]] = []
            if let existing = hooks[event] {
                // A value that is not the shape Claude Code documents is not ccmux's to
                // rewrite, and dropping it would delete a working configuration.
                guard let parsed = existing as? [[String: Any]] else { continue }
                matchers = parsed
            }
            let wantedPaths = Set(wanted[event] ?? [])
            var kept: [[String: Any]] = []
            var held = Set<String>()

            for matcher in matchers {
                guard let entries = matcher["hooks"] as? [[String: Any]] else {
                    kept.append(matcher)
                    continue
                }
                var survivors: [[String: Any]] = []
                for entry in entries {
                    guard let command = entry["command"] as? String,
                          let path = owned[event]?[canonical(command, home: home)] else {
                        survivors.append(entry)
                        continue
                    }
                    // Ours. Kept once: a command duplicated across matchers would
                    // otherwise run the script twice on every event, forever.
                    if wantedPaths.contains(path), held.insert(path).inserted {
                        survivors.append(entry)
                    } else {
                        change.unregistered.append(command)
                    }
                }
                if survivors.isEmpty, !entries.isEmpty { continue }
                var copy = matcher
                copy["hooks"] = survivors
                kept.append(copy)
            }

            // One matcher for the lot, which is the shape a hand-written config takes.
            let missing = (wanted[event] ?? []).filter { !held.contains($0) }
            if !missing.isEmpty {
                kept.append(["hooks": missing.map {
                    ["type": "command", "command": command(for: $0)]
                }])
                change.registered.append(contentsOf: missing.map(command(for:)))
            }

            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }

        var out = settings
        // Removed rather than left empty: this has to be able to leave no trace.
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
    public static func reconcile(known: [String], active: [String], settingsFile: URL,
                                 home: String = NSHomeDirectory()) throws -> Change {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsFile.path) {
            guard let data = try? Data(contentsOf: settingsFile) else {
                throw Failure.unreadable("unreadable")
            }
            // A settings.json that does not parse is the user's to fix. Overwriting it
            // would take every other setting with it.
            guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw Failure.unreadable("it is not a JSON object")
            }
            settings = object
        } else if active.isEmpty {
            return Change()
        }

        let result = apply(to: settings, known: known, active: active, home: home)
        guard !result.change.isEmpty else { return result.change }

        let data: Data
        do {
            // Slashes unescaped: the file is one people read and keep in dotfiles, and
            // `$HOME\/.claude\/…` is nobody's idea of a config.
            data = try JSONSerialization.data(withJSONObject: result.settings,
                                              options: [.prettyPrinted, .sortedKeys,
                                                        .withoutEscapingSlashes])
        } catch {
            throw Failure.write(error.localizedDescription)
        }
        sweepStaleTemporaries(beside: settingsFile)
        let tmp = settingsFile.deletingLastPathComponent()
            .appendingPathComponent(".\(settingsFile.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: settingsFile.path) {
                _ = try fm.replaceItemAt(settingsFile, withItemAt: tmp)
            } else {
                // Claude Code writes this file too, so it can appear between the check
                // and the move. Falling back beats losing the write.
                do { try fm.moveItem(at: tmp, to: settingsFile) }
                catch { _ = try fm.replaceItemAt(settingsFile, withItemAt: tmp) }
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.write(error.localizedDescription)
        }
        return result.change
    }

    /// Without this a crash between the write and the replace leaves one of these in
    /// `~/.claude` for good.
    private static func sweepStaleTemporaries(beside file: URL) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        let prefix = ".\(file.lastPathComponent)."
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".tmp") {
            try? fm.removeItem(at: dir.appendingPathComponent(entry))
        }
    }
}
