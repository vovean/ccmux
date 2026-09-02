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
        let result = HookRegistration.apply(to: settings,
                                            active: [], home: home)
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

    /// Every spelling of the same command is the same command, so an entry written by
    /// hand as `~/…` is adopted rather than duplicated alongside ccmux's own.
    @Test func everySpellingOfTheSameCommandIsRecognised() {
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [
            ["type": "command",
             "command": "/Users/tester/.claude/hooks/managed/UserPromptSubmit/a.sh"],
        ]]]]]
        let result = HookRegistration.apply(to: settings, active: ["UserPromptSubmit/a.sh"], home: home)
        #expect(commands(result.settings, "UserPromptSubmit").count == 1)
        #expect(result.change.isEmpty)
    }

    @Test func nothingIsWrittenWhenNothingChanges() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = #"{"model":"opus"}"#
        try original.write(to: file, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]

        let change = try HookRegistration.reconcile(active: [],
                                                    settingsFile: file, home: home)
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
        let result = HookRegistration.apply(to: settings,
                                            active: [], home: home)
        #expect(commands(result.settings, "UserPromptSubmit") == ["$HOME/keep.sh"])
        let matchers = (result.settings["hooks"] as? [String: Any])?["UserPromptSubmit"]
            as? [[String: Any]]
        #expect(matchers?.count == 1)
    }
    // MARK: - Review fixes

    /// The same script with an argument is the user's line, not one ccmux would ever
    /// write. Prefix-matching ownership deleted it and re-added it without the argument.
    @Test func anEntryWithArgumentsIsNotOurs() {
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [
            ["type": "command",
             "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh --verbose"],
        ]]]]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        #expect(commands(result.settings, "UserPromptSubmit")
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh --verbose"])
        #expect(result.change.isEmpty)
    }

    /// A helper at the root of the tree has no event and so is never in the active set.
    /// Owning it by prefix meant deleting a hook the user had configured by hand, on the
    /// first tick, permanently.
    @Test func aHandRegisteredHelperIsLeftWhereItIs() {
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [
            ["type": "command", "command": "$HOME/.claude/hooks/managed/helper.sh"],
        ]]]]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        #expect(commands(result.settings, "SessionStart")
            == ["$HOME/.claude/hooks/managed/helper.sh"])
        #expect(result.change.isEmpty)
    }

    /// An entry whose script the server no longer holds is exactly the one that has to be
    /// removable. Ownership deliberately does not depend on the live bundle: a withdrawn
    /// or renamed script would otherwise leave a line in the file forever, pointing at
    /// nothing and failing on every occurrence of its event.
    @Test func anEntryForAWithdrawnScriptIsStillRemoved() {
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [
            ["type": "command", "command": "$HOME/.claude/hooks/managed/UserPromptSubmit/gone.sh"],
        ]]]]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        #expect(result.settings["hooks"] == nil)
        #expect(result.change.unregistered
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/gone.sh"])
    }

    /// A value that is not the documented shape is a configuration ccmux cannot reason
    /// about. Failing the cast used to drop the whole event.
    @Test func anEventWithAnUnexpectedShapeIsNotTouched() {
        let settings: [String: Any] = ["hooks": [
            "Stop": ["something", ["hooks": []]] as [Any],
            "UserPromptSubmit": [] as [Any],
        ]]
        let result = HookRegistration.apply(to: settings, active: ["UserPromptSubmit/a.sh"], home: home)
        let hooks = try? #require(result.settings["hooks"] as? [String: Any])
        #expect((hooks?["Stop"] as? [Any])?.count == 2)
        #expect(commands(result.settings, "UserPromptSubmit")
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"])
    }

    /// A matcher without a hooks array is someone else's object; it must not acquire an
    /// empty one.
    @Test func aMatcherWithNoHooksArrayIsPassedThrough() {
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [
            ["matcher": "*"],
        ]]]
        let result = HookRegistration.apply(to: settings, active: [], home: home)
        let matchers = result.settings["hooks"].flatMap { ($0 as? [String: Any]) }
            .flatMap { $0["UserPromptSubmit"] as? [[String: Any]] }
        #expect(matchers?.first?["hooks"] == nil)
    }

    /// Two copies of the same command run the script twice on every event.
    @Test func aDuplicatedManagedCommandIsCollapsed() {
        let cmd = "$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"
        let settings: [String: Any] = ["hooks": ["UserPromptSubmit": [
            ["hooks": [["type": "command", "command": cmd]]],
            ["hooks": [["type": "command", "command": cmd]]],
        ]]]
        let result = HookRegistration.apply(to: settings, active: ["UserPromptSubmit/a.sh"], home: home)
        #expect(commands(result.settings, "UserPromptSubmit") == [cmd])
        // Reported as a duplicate rather than a removal: "1 removed" in the log for a
        // hook that is still registered reads as ccmux unregistering a live one.
        #expect(result.change.deduplicated == [cmd])
        #expect(result.change.unregistered.isEmpty)
    }

    /// Several scripts under one event belong in one matcher, which is the shape a
    /// hand-written config takes.
    @Test func severalScriptsUnderOneEventShareOneMatcher() {
        let result = HookRegistration.apply(
            to: [:], active: ["UserPromptSubmit/a.sh", "UserPromptSubmit/b.sh"], home: home)
        let matchers = (result.settings["hooks"] as? [String: Any])?["UserPromptSubmit"]
            as? [[String: Any]]
        #expect(matchers?.count == 1)
        #expect(commands(result.settings, "UserPromptSubmit").count == 2)
    }

    /// An active script under no known event is reported, not dropped in silence — that
    /// reads exactly like a hook that simply never fires.
    @Test func anActiveScriptWithNoEventIsReported() {
        let result = HookRegistration.apply(to: [:], active: ["helper.sh"], home: home)
        #expect(result.change.unregisterable == ["helper.sh"])
        #expect(result.change.isEmpty)
    }

    /// The file is one people read and keep in dotfiles.
    @Test func pathsAreWrittenWithoutEscapedSlashes() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try #"{"model":"opus"}"#.write(to: file, atomically: true, encoding: .utf8)
        try HookRegistration.reconcile(active: ["UserPromptSubmit/a.sh"],
                                       settingsFile: file, home: home)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("\\/"))
        #expect(text.contains("$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"))
    }

    /// A crash between the write and the replace would otherwise leave one of these in
    /// ~/.claude for good.
    @Test func aStrandedTemporaryIsSweptOnTheNextWrite() throws {
        let file = settingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try #"{"model":"opus"}"#.write(to: file, atomically: true, encoding: .utf8)
        let stranded = file.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.\(UUID().uuidString).tmp")
        try Data("junk".utf8).write(to: stranded)
        // Aged past the floor. A fresh one is left alone on purpose — it may be another
        // writer's, mid-write.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: stranded.path)
        let fresh = file.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.fresh.tmp")
        try Data("in flight".utf8).write(to: fresh)

        try HookRegistration.reconcile(active: ["UserPromptSubmit/a.sh"],
                                       settingsFile: file, home: home)
        #expect(!FileManager.default.fileExists(atPath: stranded.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// A rename orphans the old path the same way a withdrawal does.
    @Test func aRenamedScriptDoesNotStrandItsOldEntry() {
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["hooks": [
            ["type": "command", "command": "$HOME/.claude/hooks/managed/PreToolUse/a.sh"],
        ]]]]]
        let result = HookRegistration.apply(to: settings, active: ["PreToolUse/b.sh"],
                                            home: home)
        #expect(commands(result.settings, "PreToolUse")
            == ["$HOME/.claude/hooks/managed/PreToolUse/b.sh"])
        #expect(result.change.unregistered
            == ["$HOME/.claude/hooks/managed/PreToolUse/a.sh"])
    }

    /// An event whose value ccmux cannot parse must not swallow the scripts filed under
    /// it in silence — that reads exactly like a hook that never fires.
    @Test func activeScriptsUnderAnUnparseableEventAreReported() {
        let settings: [String: Any] = ["hooks": ["Stop": ["nonsense"] as [Any]]]
        let result = HookRegistration.apply(to: settings, active: ["Stop/a.sh"], home: home)
        #expect(result.change.unregisterable == ["Stop/a.sh"])
        #expect((result.settings["hooks"] as? [String: Any])?["Stop"] as? [String]
            == ["nonsense"])
    }

    /// An event the user left as an empty array is theirs, and must not disappear as a
    /// side effect of an unrelated registration.
    @Test func anEventTheUserLeftEmptyIsNotDeleted() {
        let settings: [String: Any] = ["hooks": ["Stop": [] as [Any],
                                                 "UserPromptSubmit": [] as [Any]]]
        let result = HookRegistration.apply(to: settings, active: ["UserPromptSubmit/a.sh"],
                                            home: home)
        let hooks = result.settings["hooks"] as? [String: Any]
        #expect(hooks?["Stop"] != nil)
        #expect(commands(result.settings, "UserPromptSubmit")
            == ["$HOME/.claude/hooks/managed/UserPromptSubmit/a.sh"])
    }

}
