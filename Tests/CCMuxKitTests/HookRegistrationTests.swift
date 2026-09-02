import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Hook registration")
struct HookRegistrationTests {
    private let home = "/Users/tester"

    private func settingsFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-reg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let matchers = hooks[event] as? [[String: Any]] ?? []
        return matchers.flatMap { ($0["hooks"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String } }
    }

    /// The event comes from the first path segment. Anything else must not be written —
    /// the value lands in a config Claude Code parses.
    @Test func onlyAScriptUnderAKnownEventDirectoryRegisters() {
        #expect(HookRegistration.event(for: "UserPromptSubmit/a.sh") == "UserPromptSubmit")
        #expect(HookRegistration.event(for: "PreToolUse/x/y.sh") == "PreToolUse")
        for bad in ["a.sh", "helpers/a.sh", "userpromptsubmit/a.sh", ""] {
            #expect(HookRegistration.event(for: bad) == nil, "accepted \(bad)")
        }
    }

    /// The whole reason this is allowed to touch the file at all: everything that is not
    /// ccmux's survives untouched, including hooks under the same event.
    @Test func everythingThatIsNotOursIsLeftAlone() {
        let settings: [String: Any] = [
            "model": "opus", "permissions": ["allow": ["Bash"]],
            "hooks": [
                "SessionStart": [["hooks": [["type": "command",
                                             "command": "/Users/tester/.claude/hooks/cleanup.sh"]]]],
                "UserPromptSubmit": [["hooks": [["type": "command",
                                                 "command": "$HOME/other/thing.sh"]]]],
            ],
        ]
        let result = HookRegistration.apply(to: settings,
                                            active: ["UserPromptSubmit/fable.sh"],
                                            home: home)
        #expect(result.settings["model"] as? String == "opus")
        #expect((result.settings["permissions"] as? [String: Any])?["allow"] != nil)
        #expect(commands(result.settings, "SessionStart")
            == ["/Users/tester/.claude/hooks/cleanup.sh"])
        #expect(commands(result.settings, "UserPromptSubmit").sorted()
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/fable.sh",
                "$HOME/other/thing.sh"])
        #expect(result.change.registered
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/fable.sh"])
    }

    /// Deactivating has to take the entry back out, or the switch only ever adds.
    @Test func aDeactivatedScriptIsUnregistered() {
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": [["hooks": [
                ["type": "command", "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"],
                ["type": "command", "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/b.sh"],
            ]]],
        ]]
        let result = HookRegistration.apply(to: settings,
                                            active: ["UserPromptSubmit/b.sh"], home: home)
        #expect(commands(result.settings, "UserPromptSubmit")
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/b.sh"])
        #expect(result.change.unregistered
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"])
    }

    /// Turning the switch off has to leave the file as if ccmux had never been there,
    /// including dropping an events key and the hooks object it emptied.
    @Test func registeringNothingLeavesNoTrace() {
        let settings: [String: Any] = ["model": "opus", "hooks": [
            "UserPromptSubmit": [["hooks": [["type": "command",
                                             "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"]]]],
        ]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        #expect(result.settings["hooks"] == nil)
        #expect(result.settings["model"] as? String == "opus")
    }

    /// The user registered this hook by hand before ccmux could. Writing a second entry
    /// would run the script twice on every prompt.
    @Test func anEntryTheUserWroteByHandIsAdoptedNotDuplicated() {
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": [["hooks": [["type": "command",
                                             "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"]]]],
        ]]
        let result = HookRegistration.apply(to: settings,
                                            active: ["UserPromptSubmit/a.sh"], home: home)
        #expect(commands(result.settings, "UserPromptSubmit").count == 1)
        #expect(result.change.isEmpty)
    }

    /// An absolute spelling of the same directory is still ours; missing it would leave a
    /// stale entry pointing at a script that has been deactivated everywhere.
    @Test func anAbsolutePathIntoTheManagedDirectoryIsAlsoOurs() {
        #expect(HookRegistration.isManaged("/Users/tester/.claude/hooks/managed/a.sh",
                                           home: home))
        #expect(HookRegistration.isManaged("~/.claude/hooks/managed/a.sh", home: home))
        #expect(HookRegistration.isManaged("${HOME}/.claude/hooks/managed/a.sh", home: home))
        #expect(!HookRegistration.isManaged("$HOME/.claude/hooks/other.sh", home: home))
        #expect(!HookRegistration.isManaged("/usr/local/bin/thing", home: home))
    }

    @Test func nothingIsWrittenWhenNothingChanges() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = #"{"model":"opus"}"#
        try original.write(to: file, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]

        let change = try HookRegistration.reconcile(active: [], settingsFile: file,
                                                    home: home)
        #expect(change.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        #expect(before as? Date == after as? Date)
    }

    /// A settings.json that does not parse is the user's to fix. Rewriting it from an
    /// empty object would take every other setting in it with them.
    @Test func anUnparseableSettingsFileIsRefusedRatherThanReplaced() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let broken = "{ this is not json"
        try broken.write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: HookRegistration.Failure.unreadable("it is not a JSON object")) {
            try HookRegistration.reconcile(active: ["UserPromptSubmit/a.sh"],
                                           settingsFile: file, home: home)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
    }

    @Test func aRoundTripThroughTheFileKeepsEveryOtherKey() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original: [String: Any] = [
            "model": "opus", "autoCompactEnabled": true,
            "env": ["FOO": "bar"], "enabledPlugins": ["a", "b"],
            "hooks": ["SessionStart": [["hooks": [["type": "command",
                                                   "command": "$HOME/mine.sh"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: file)

        try HookRegistration.reconcile(active: ["UserPromptSubmit/a.sh"],
                                       settingsFile: file, home: home)
        let after = read(file)
        #expect(after["model"] as? String == "opus")
        #expect(after["autoCompactEnabled"] as? Bool == true)
        #expect((after["env"] as? [String: Any])?["FOO"] as? String == "bar")
        #expect(after["enabledPlugins"] as? [String] == ["a", "b"])
        #expect(commands(after, "SessionStart") == ["$HOME/mine.sh"])
        #expect(commands(after, "UserPromptSubmit")
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"])
    }

    /// A matcher whose only entry was ours must go, rather than linger as an empty
    /// matcher Claude Code still has to parse.
    @Test func anEmptiedMatcherIsRemoved() {
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": [
                ["matcher": "*", "hooks": [["type": "command",
                                            "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"]]],
                ["hooks": [["type": "command", "command": "$HOME/keep.sh"]]],
            ],
        ]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        #expect(commands(result.settings, "UserPromptSubmit") == ["$HOME/keep.sh"])
        let matchers = (result.settings["hooks"] as? [String: Any])?["UserPromptSubmit"]
            as? [[String: Any]]
        #expect(matchers?.count == 1)
    }
}
