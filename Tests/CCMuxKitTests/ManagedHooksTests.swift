import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Managed hooks")
struct ManagedHooksTests {
    /// Each root gets its own container, because `apply` stages into a *sibling* of the
    /// managed directory — sharing one parent across parallel tests makes them see each
    /// other's staging trees.
    private func temp() -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-hooks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: container,
                                                 withIntermediateDirectories: true)
        return container.appendingPathComponent("managed", isDirectory: true)
    }

    private func bundle(_ files: [HookFile]) -> HookBundle {
        HookBundle(version: ManagedHooks.version(of: files), files: files)
    }

    /// These files are written to disk and then executed, so a path that tries to leave
    /// the managed directory is refused rather than cleaned up.
    @Test func aPathMayNotEscapeTheManagedDirectory() {
        for bad in ["../evil.sh", "..", "/etc/evil", "a/../../evil.sh", "a//b.sh",
                    "./a.sh", "a/./b.sh", "back\\slash.sh", "", ".hidden",
                    "dir/.hidden", "a/b/c/d/e.sh",
                    // Non-ASCII would make Go's byte order and Swift's collation disagree
                    // about how to sort the bundle, so the two hash it differently.
                    "\u{e1}.sh", "e\u{301}.sh", "with space.sh", "semi;colon.sh"] {
            #expect(ManagedHooks.validate(bad) != nil, "accepted \(bad)")
        }
        for good in ["a.sh", "UserPromptSubmit/fable.sh", "a/b/c.sh"] {
            #expect(ManagedHooks.validate(good) == nil, "rejected \(good)")
        }
    }

    /// The client and the server must hash a bundle identically. If they disagree the
    /// versions never match, and every Mac rewrites the whole set once a minute forever
    /// while reporting itself in sync — a silent, permanent loop.
    @Test func theVersionMatchesTheServersHashForTheSameBundle() {
        let files = [HookFile(path: "b.sh", content: "two\n", executable: true),
                     HookFile(path: "a.sh", content: "one", executable: false)]
        // Computed by ccmuxd's hookVersion over the same two files.
        #expect(ManagedHooks.version(of: files)
            == "4aa9be43c6cc80431061ee09c0a9af05be6dc7a285fd5be8fb1ed3b46d18bbd9")
    }

    @Test func writingSetsTheExecutableBitOnlyWhereAsked() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ManagedHooks.apply(bundle([
            HookFile(path: "UserPromptSubmit/run.sh", content: "#!/bin/sh\n", executable: true),
            HookFile(path: "notes.txt", content: "plain", executable: false),
        ]), into: root)

        let fm = FileManager.default
        let script = root.appendingPathComponent("UserPromptSubmit/run.sh").path
        let notes = root.appendingPathComponent("notes.txt").path
        let scriptMode = try #require(fm.attributesOfItem(atPath: script)[.posixPermissions] as? Int)
        let notesMode = try #require(fm.attributesOfItem(atPath: notes)[.posixPermissions] as? Int)
        #expect(scriptMode & 0o100 != 0)
        #expect(notesMode & 0o100 == 0)
        // Never group- or world-readable: these run with the user's full authority.
        #expect(scriptMode & 0o077 == 0)
    }

    /// The directory is owned outright, so a hook withdrawn centrally stops running here
    /// rather than lingering on whichever Mac happened to have it.
    @Test func aFileThatLeavesTheBundleIsRemoved() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ManagedHooks.apply(bundle([
            HookFile(path: "keep.sh", content: "a", executable: true),
            HookFile(path: "drop.sh", content: "b", executable: true),
        ]), into: root)
        let result = try ManagedHooks.apply(bundle([
            HookFile(path: "keep.sh", content: "a", executable: true),
        ]), into: root)
        #expect(result.removed == ["drop.sh"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drop.sh").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.sh").path))
    }

    /// A rejected path stops the whole apply. Half a hook set is a state nobody published.
    @Test func oneBadPathRefusesTheWholeBundle() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) {
            try ManagedHooks.apply(self.bundle([
                HookFile(path: "good.sh", content: "a", executable: true),
                HookFile(path: "../escape.sh", content: "b", executable: true),
            ]), into: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("good.sh").path))
    }

    /// Derived from disk rather than a marker, so a hand-edited or deleted hook is noticed
    /// and restored instead of being assumed present.
    @Test func theInstalledVersionTracksWhatIsActuallyOnDisk() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let wanted = bundle([HookFile(path: "a.sh", content: "original", executable: true)])
        try ManagedHooks.apply(wanted, into: root)
        #expect(ManagedHooks.installedVersion(in: root) == wanted.version)

        try "tampered".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                             encoding: .utf8)
        #expect(ManagedHooks.installedVersion(in: root) != wanted.version)

        try FileManager.default.removeItem(at: root.appendingPathComponent("a.sh"))
        #expect(ManagedHooks.installedVersion(in: root) != wanted.version)
    }

    /// APFS is case-insensitive: writing fable.sh over an existing Fable.sh keeps the old
    /// directory entry, so the prune then deleted the file it had just written — every
    /// tick, forever, while logging success.
    @Test func aCaseOnlyRenameLeavesTheFileInstalled() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ManagedHooks.apply(bundle([HookFile(path: "Fable.sh", content: "v1",
                                                executable: true)]), into: root)
        let renamed = bundle([HookFile(path: "fable.sh", content: "v2", executable: true)])
        try ManagedHooks.apply(renamed, into: root)

        let installed = ManagedHooks.onDisk(in: root)
        #expect(installed.count == 1)
        #expect(installed.first?.content == "v2")
        // The property that actually matters: the version converges, so the next tick has
        // nothing to do.
        #expect(ManagedHooks.installedVersion(in: root) == renamed.version)
    }

    /// A bundle that cannot be built must leave the running hooks exactly as they were —
    /// half of one revision beside half of another is the state the whole design avoids.
    @Test func abundleThatCannotBeBuiltLeavesThePreviousTreeIntact() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let good = bundle([HookFile(path: "keep.sh", content: "original", executable: true)])
        try ManagedHooks.apply(good, into: root)

        // `tools` as a file and as a parent directory cannot both exist. The server
        // refuses this pair now; the client must not corrupt itself if one ever arrives.
        #expect(throws: (any Error).self) {
            try ManagedHooks.apply(self.bundle([
                HookFile(path: "tools", content: "a", executable: true),
                HookFile(path: "tools/helper.sh", content: "b", executable: true),
            ]), into: root)
        }
        #expect(ManagedHooks.installedVersion(in: root) == good.version)
        #expect(try String(contentsOf: root.appendingPathComponent("keep.sh"),
                           encoding: .utf8) == "original")
    }

    /// Staging trees hold executable files; one left behind per interruption would
    /// accumulate forever, invisible to the prune.
    @Test func noStagingDirectoryIsLeftBehind() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try ManagedHooks.apply(bundle([HookFile(path: "a.sh", content: "x",
                                                executable: true)]), into: root)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: root.deletingLastPathComponent().path)) ?? []
        #expect(!siblings.contains { $0.contains(".staging-") })
    }

    /// A degenerate 200 must fail the decode rather than decode to an empty set: the
    /// bundle decides which executable files get deleted, and "" never matches the
    /// installed hash, so a lenient decoder made every malformed answer an instruction to
    /// remove every hook on the machine.
    @Test func adegenerateBundleFailsToDecodeRatherThanMeaningDeleteEverything() {
        let decoder = JSONDecoder()
        for bad in [#"{"apiVersion":1}"#,
                    #"{"apiVersion":1,"version":"abc"}"#,
                    #"{"apiVersion":1,"files":[]}"#,
                    #"{"apiVersion":1,"version":"","files":[]}"#] {
            #expect(throws: (any Error).self) {
                _ = try decoder.decode(HookBundle.self, from: Data(bad.utf8))
            }
        }
        // A genuinely empty set is still expressible, and still decodes.
        let empty = #"{"apiVersion":1,"version":"e3b0c442","files":[]}"#
        let decoded = try? decoder.decode(HookBundle.self, from: Data(empty.utf8))
        #expect(decoded?.files.isEmpty == true)
        #expect(decoded?.version == "e3b0c442")
    }

    @Test func anEmptyRootHashesTheSameAsAnEmptyBundle() {
        let missing = temp()
        #expect(ManagedHooks.installedVersion(in: missing) == ManagedHooks.version(of: []))
    }

    /// A symlink is not one of ours and must not be written through: reported as absent so
    /// the next apply replaces it with a real file.
    @Test func aSymlinkIsNotTreatedAsAnInstalledHook() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).sh")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.sh"),
                                                   withDestinationURL: outside)
        #expect(ManagedHooks.onDisk(in: root).isEmpty)

        // Replacing it must write a real file and leave the symlink's target untouched.
        try ManagedHooks.apply(bundle([HookFile(path: "a.sh", content: "real",
                                                executable: true)]), into: root)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secret")
        #expect(try String(contentsOf: root.appendingPathComponent("a.sh"),
                           encoding: .utf8) == "real")
    }
}
