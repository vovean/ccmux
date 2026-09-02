import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Hook sync")
struct HookSyncTests {
    /// Each root gets its own container: `apply` stages into a *sibling* of the managed
    /// directory, so sharing one parent across parallel tests makes them see each other's
    /// staging trees.
    private func temp() -> (root: URL, baseline: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-hooksync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: container,
                                                 withIntermediateDirectories: true)
        return (container.appendingPathComponent("managed", isDirectory: true),
                container.appendingPathComponent("baseline.json"))
    }

    private func file(_ path: String, _ content: String) -> HookFile {
        HookFile(path: path, content: content, executable: true)
    }

    private func baseline(_ files: [HookFile]) -> HookBaseline {
        HookBaseline(files: files.reduce(into: [:]) {
            $0[$1.path] = HookBaseline.Entry(digest: ManagedHooks.digest(of: $1),
                                             syncedAt: Date(timeIntervalSince1970: 1))
        })
    }

    private func state(local: [HookFile], server: [HookFile]?,
                       base: HookBaseline?, _ path: String) -> ManagedHook.State? {
        HookSync.classify(local: local, server: server, baseline: base)
            .first { $0.path == path }?.state
    }

    // MARK: - Classification

    /// The whole point of the baseline is that these nine cases are distinguishable.
    /// Without it "the server changed" and "this Mac changed" are the same observation,
    /// and the sync answers both by overwriting.
    @Test func everyCombinationOfTheThreeCopiesLandsInTheRightState() {
        let old = file("a.sh", "old")
        let mine = file("a.sh", "mine")
        let theirs = file("a.sh", "theirs")
        let base = baseline([old])

        #expect(state(local: [old], server: [old], base: base, "a.sh") == .inSync)
        // Same content reached from different directions is still the same content.
        #expect(state(local: [mine], server: [mine], base: base, "a.sh") == .inSync)
        #expect(state(local: [old], server: [theirs], base: base, "a.sh") == .stale)
        #expect(state(local: [mine], server: [old], base: base, "a.sh") == .editedHere)
        #expect(state(local: [mine], server: [theirs], base: base, "a.sh") == .conflict)
        // Published centrally and not written here yet.
        #expect(state(local: [], server: [theirs], base: HookBaseline(), "a.sh") == .stale)
        // Withdrawn centrally, untouched here.
        #expect(state(local: [old], server: [], base: base, "a.sh") == .stale)
        // Withdrawn centrally *and* edited here — the user chooses.
        #expect(state(local: [mine], server: [], base: base, "a.sh") == .conflict)
        // Written here and never published.
        #expect(state(local: [mine], server: [], base: HookBaseline(), "a.sh") == .editedHere)
    }

    /// The executable bit is part of a file's identity — the same text at two modes is
    /// not the same install, and a hook that arrives non-executable silently never runs.
    @Test func aChangedModeCountsAsAChange() {
        let executable = HookFile(path: "a.sh", content: "x", executable: true)
        let plain = HookFile(path: "a.sh", content: "x", executable: false)
        #expect(state(local: [plain], server: [executable],
                      base: baseline([plain]), "a.sh") == .stale)
    }

    /// A file deleted by hand is put back without asking. Deleting a hook is almost never
    /// a considered edit, and the failure mode is invisible: the hook simply stops running
    /// with nothing to notice.
    @Test func aLocallyDeletedHookIsRestoredRatherThanQueried() {
        let hook = file("a.sh", "one")
        #expect(state(local: [], server: [hook], base: baseline([hook]), "a.sh") == .stale)
        #expect(!HookSync.classify(local: [], server: [hook], baseline: baseline([hook]))
            .contains { $0.needsDecision })
    }

    /// The first tick after this feature ships has no baseline, and the only honest answer
    /// then is the one the sync has always given. Freezing instead would strand every Mac
    /// on the upgrade over content nobody has disagreed about.
    @Test func withNoBaselineAtAllTheServerStillWins() {
        let mine = file("a.sh", "mine")
        let theirs = file("a.sh", "theirs")
        #expect(state(local: [mine], server: [theirs], base: nil, "a.sh") == .stale)
        #expect(!HookSync.classify(local: [mine], server: [theirs], baseline: nil)
            .contains { $0.needsDecision })
    }

    /// With no server copy, "in sync" and "edited here" are the same observation, so
    /// neither is claimed.
    @Test func anUnreachableServerLeavesEveryFileUnknown() {
        let hooks = HookSync.classify(local: [file("a.sh", "one")], server: nil,
                                      baseline: baseline([file("a.sh", "one")]))
        #expect(hooks.map(\.state) == [.unknown])
        #expect(hooks[0].syncedAt == Date(timeIntervalSince1970: 1))
        #expect(!hooks.contains { $0.needsDecision })
    }

    // MARK: - Reconciling

    @Test func aStaleSetIsWrittenWithoutAsking() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "v2"), file("b.sh", "b")]
        _ = try HookSync.install([file("a.sh", "v1")], server: [file("a.sh", "v1")],
                                 root: root, baselineFile: baselineFile)

        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(result.applied)
        #expect(result.failure == nil)
        #expect(result.hooks.allSatisfy { $0.state == .inSync })
        #expect(try String(contentsOf: root.appendingPathComponent("a.sh"),
                           encoding: .utf8) == "v2")
    }

    /// The load-bearing half of the feature: while anything is waiting on the user, the
    /// managed directory is not written at all. The apply builds the whole tree in one
    /// swap, so letting an unrelated stale file through would take the edit with it.
    @Test func oneLocalEditHoldsTheWholeTree() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let published = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(published, server: published, root: root,
                                 baselineFile: baselineFile)
        try "edited".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                           encoding: .utf8)

        let server = [file("a.sh", "a1"), file("b.sh", "b2")]
        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(!result.applied)
        #expect(result.hooks.first { $0.path == "a.sh" }?.state == .editedHere)
        #expect(result.hooks.first { $0.path == "b.sh" }?.state == .stale)
        #expect(try String(contentsOf: root.appendingPathComponent("a.sh"),
                           encoding: .utf8) == "edited")
        // The stale file is held back too, and that is the cost being paid on purpose.
        #expect(try String(contentsOf: root.appendingPathComponent("b.sh"),
                           encoding: .utf8) == "b1")
    }

    /// A file dropped into the managed directory used to be deleted within the minute.
    /// It has to survive long enough to be published, or the page cannot be where hooks
    /// are written.
    @Test func aNewLocalFileIsNotDeletedOnTheNextTick() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "a1")]
        _ = try HookSync.install(server, server: server, root: root,
                                 baselineFile: baselineFile)
        try "fresh".write(to: root.appendingPathComponent("new.sh"), atomically: true,
                          encoding: .utf8)

        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(!result.applied)
        #expect(result.hooks.first { $0.path == "new.sh" }?.state == .editedHere)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("new.sh").path))
    }

    /// A Mac that already matched the server when this shipped never applies anything, so
    /// without recording the agreement here it would never get a baseline — and every edit
    /// it ever made would read as corruption and be overwritten.
    @Test func aMacThatIsAlreadyInSyncStillGetsABaseline() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "a1")]
        try ManagedHooks.apply(HookBundle(version: ManagedHooks.version(of: server),
                                          files: server), into: root)
        #expect(HookBaseline.load(from: baselineFile) == nil)

        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(!result.applied)
        #expect(HookBaseline.load(from: baselineFile)?.files["a.sh"]?.digest
            == ManagedHooks.digest(of: server[0]))

        // And now an edit is an edit rather than damage.
        try "edited".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                           encoding: .utf8)
        #expect(HookSync.reconcile(server: server,
                                   serverVersion: ManagedHooks.version(of: server),
                                   root: root, baselineFile: baselineFile)
            .hooks.first?.state == .editedHere)
    }

    /// A file's stamp is when its content arrived, not when the tick last ran, so an
    /// untouched hook does not claim to have synced a minute ago.
    @Test func aFilesSyncedAtMovesOnlyWhenItsContentDoes() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = [file("a.sh", "a1"), file("b.sh", "b1")]
        let long = Date(timeIntervalSince1970: 1_000_000)
        _ = try HookSync.install(first, server: first, root: root,
                                 baselineFile: baselineFile, now: long)

        let second = [file("a.sh", "a1"), file("b.sh", "b2")]
        let later = Date(timeIntervalSince1970: 2_000_000)
        _ = try HookSync.install(second, server: second, root: root,
                                 baselineFile: baselineFile, now: later)

        let stored = HookBaseline.load(from: baselineFile)
        #expect(stored?.files["a.sh"]?.syncedAt == long)
        #expect(stored?.files["b.sh"]?.syncedAt == later)
    }

    // MARK: - Resolving

    /// Answering one question must not silently answer the rest: every other undecided
    /// file keeps what is on this Mac, even though the write is one whole-tree swap.
    @Test func takingTheServersCopyLeavesOtherHeldFilesAlone() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let published = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(published, server: published, root: root,
                                 baselineFile: baselineFile)
        try "mine-a".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                           encoding: .utf8)
        try "mine-b".write(to: root.appendingPathComponent("b.sh"), atomically: true,
                           encoding: .utf8)

        let hooks = HookSync.classify(local: ManagedHooks.onDisk(in: root),
                                      server: published,
                                      baseline: HookBaseline.load(from: baselineFile))
        #expect(hooks.allSatisfy { $0.state == .editedHere })

        let tree = try HookSync.treeTakingServer("a.sh", in: hooks)
        let after = try HookSync.install(tree, server: published, root: root,
                                         baselineFile: baselineFile)
        #expect(try String(contentsOf: root.appendingPathComponent("a.sh"),
                           encoding: .utf8) == "a1")
        #expect(try String(contentsOf: root.appendingPathComponent("b.sh"),
                           encoding: .utf8) == "mine-b")
        #expect(after.hooks.first { $0.path == "a.sh" }?.state == .inSync)
        // The kept file keeps its old base, so it is still a question rather than an
        // agreement nobody made.
        #expect(after.hooks.first { $0.path == "b.sh" }?.state == .editedHere)
    }

    /// Both ends deal in whole bundles, but publishing one file must not publish every
    /// other unanswered edit along with it.
    @Test func publishingOneFileSendsTheServersSetWithJustThatFileSwapped() {
        let server = [file("a.sh", "a1"), file("b.sh", "b1")]
        let hooks = HookSync.classify(local: [file("a.sh", "mine-a"),
                                              file("b.sh", "mine-b")],
                                      server: server, baseline: baseline(server))
        let bundle = HookSync.bundlePublishing("a.sh", in: hooks)
        #expect(bundle?.sorted { $0.path < $1.path }.map(\.content) == ["mine-a", "b1"])
    }

    /// The server's copy of a withdrawn file is gone, so taking it means removing the
    /// file here — the button says Delete for exactly this case.
    @Test func takingTheServersCopyOfAWithdrawnFileRemovesIt() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let published = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(published, server: published, root: root,
                                 baselineFile: baselineFile)
        try "mine".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                         encoding: .utf8)

        let server = [file("b.sh", "b1")]
        let hooks = HookSync.classify(local: ManagedHooks.onDisk(in: root), server: server,
                                      baseline: HookBaseline.load(from: baselineFile))
        #expect(hooks.first { $0.path == "a.sh" }?.state == .conflict)

        _ = try HookSync.install(HookSync.treeTakingServer("a.sh", in: hooks),
                                 server: server, root: root, baselineFile: baselineFile)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("a.sh").path))
        // The baseline must forget it too, or restoring it later reads as a local edit.
        #expect(HookBaseline.load(from: baselineFile)?.files["a.sh"] == nil)
    }

    /// After a publish the server holds this Mac's copy, so the next reconcile settles the
    /// file and releases everything the freeze was holding back.
    @Test func aPublishReleasesTheHeldSet() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let published = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(published, server: published, root: root,
                                 baselineFile: baselineFile)
        try "mine".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                         encoding: .utf8)

        // What the server holds once the Upload button's bundle lands, with b.sh moved on
        // in the meantime.
        let afterPush = [file("a.sh", "mine"), file("b.sh", "b2")]
        let result = HookSync.reconcile(server: afterPush,
                                        serverVersion: ManagedHooks.version(of: afterPush),
                                        root: root, baselineFile: baselineFile)
        #expect(result.applied)
        #expect(result.hooks.allSatisfy { $0.state == .inSync })
        #expect(try String(contentsOf: root.appendingPathComponent("b.sh"),
                           encoding: .utf8) == "b2")
    }

    // MARK: - Review fixes

    /// A stray with a name the bundle rules refuse can never be published, so treating it
    /// as an edit held the whole sync on a file no button could settle. It is left out of
    /// the states — but not out of the sweep, or it would vanish with nothing said.
    @Test func aFileWithAnUnpublishableNameIsSweptRatherThanHeldOrHidden() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "a1")]
        _ = try HookSync.install(server, server: server, root: root,
                                 baselineFile: baselineFile)
        // What Finder's Duplicate produces.
        let stray = root.appendingPathComponent("a copy.sh")
        try "stray".write(to: stray, atomically: true, encoding: .utf8)

        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(result.hooks.map(\.path) == ["a.sh"])
        #expect(!result.hooks.contains { $0.needsDecision })
        // Swept, and reported as removed so the log says where it went.
        #expect(result.applied)
        #expect(result.removed == ["a copy.sh"])
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    /// APFS folds case, so staging both would collapse them into one entry and lose the
    /// held local file without a word.
    @Test func aCaseCollisionRefusesTheResolutionRatherThanLosingAFile() throws {
        let server = [file("A.sh", "theirs"), file("c.sh", "c")]
        let hooks = HookSync.classify(local: [file("a.sh", "mine"), file("c.sh", "c")],
                                      server: server,
                                      baseline: baseline([file("a.sh", "was"),
                                                          file("c.sh", "c")]))
        #expect(hooks.first { $0.path == "a.sh" }?.state == .conflict)
        // Named held-first: A.sh is the server's and its row has no buttons, so pointing
        // the user at it would be a dead end that looks like a wedge.
        #expect(throws: HookSync.Failure.pathCollision("a.sh", "A.sh")) {
            try HookSync.treeTakingServer("c.sh", in: hooks)
        }
        // Settling the collided file itself is the way out, and it must still work.
        #expect(try HookSync.treeTakingServer("a.sh", in: hooks).map(\.path).sorted()
            == ["A.sh", "c.sh"])
    }

    /// A file that already matches the server is agreed no matter what else is held.
    /// Skipping the record turned the next ordinary edit of it into a phantom conflict
    /// about a server change that never happened.
    @Test func agreementIsRecordedForSettledFilesEvenWhileAnotherIsHeld() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(first, server: first, root: root,
                                 baselineFile: baselineFile)
        // a.sh is published anew from this Mac while b.sh stays held.
        try "a2".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                       encoding: .utf8)
        try "mine".write(to: root.appendingPathComponent("b.sh"), atomically: true,
                         encoding: .utf8)
        let afterPush = [file("a.sh", "a2"), file("b.sh", "b1")]

        _ = HookSync.reconcile(server: afterPush,
                               serverVersion: ManagedHooks.version(of: afterPush),
                               root: root, baselineFile: baselineFile)
        #expect(HookBaseline.load(from: baselineFile)?.files["a.sh"]?.digest
            == ManagedHooks.digest(of: afterPush[0]))

        // So editing it again is an edit, not a conflict.
        try "a3".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                       encoding: .utf8)
        let hooks = HookSync.reconcile(server: afterPush,
                                       serverVersion: ManagedHooks.version(of: afterPush),
                                       root: root, baselineFile: baselineFile).hooks
        #expect(hooks.first { $0.path == "a.sh" }?.state == .editedHere)
    }

    /// The record must not run before the classification on a first-ever sync: it would
    /// hand the bootstrap a non-empty baseline, and every file edited before the upgrade
    /// would read as a conflict instead of taking the server's copy.
    @Test func recordingAgreementDoesNotBreakTheFirstEverSync() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "theirs"), file("b.sh", "same")]
        try ManagedHooks.apply(HookBundle(version: "x",
                                          files: [file("a.sh", "mine"),
                                                  file("b.sh", "same")]), into: root)
        #expect(HookBaseline.load(from: baselineFile) == nil)

        let result = HookSync.reconcile(server: server,
                                        serverVersion: ManagedHooks.version(of: server),
                                        root: root, baselineFile: baselineFile)
        #expect(result.applied)
        #expect(result.hooks.allSatisfy { $0.state == .inSync })
        #expect(try String(contentsOf: root.appendingPathComponent("a.sh"),
                           encoding: .utf8) == "theirs")
    }

    /// Pins the pattern `resolveHook` has to follow. A tree built from the page's
    /// snapshot writes that snapshot's copy of every *other* retained file, so an edit
    /// made since — through the page's own open-in-VS-Code button — is silently reverted
    /// and then recorded as agreed. Resolving has to re-read disk first.
    @Test func aTreeMustBeBuiltFromDiskNowRatherThanTheLastSnapshot() throws {
        let (root, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = [file("a.sh", "a1"), file("b.sh", "b1")]
        _ = try HookSync.install(server, server: server, root: root,
                                 baselineFile: baselineFile)
        try "mine-a".write(to: root.appendingPathComponent("a.sh"), atomically: true,
                           encoding: .utf8)

        let snapshot = HookSync.classify(local: ManagedHooks.onDisk(in: root),
                                         server: server,
                                         baseline: HookBaseline.load(from: baselineFile))
        // The user then edits the other file through the page.
        try "mine-b".write(to: root.appendingPathComponent("b.sh"), atomically: true,
                           encoding: .utf8)

        let stale = try HookSync.treeTakingServer("a.sh", in: snapshot)
        #expect(stale.first { $0.path == "b.sh" }?.content == "b1")

        let fresh = HookSync.classify(local: ManagedHooks.onDisk(in: root), server: server,
                                      baseline: HookBaseline.load(from: baselineFile))
        let kept = try HookSync.treeTakingServer("a.sh", in: fresh)
        #expect(kept.first { $0.path == "b.sh" }?.content == "mine-b")
        #expect(kept.first { $0.path == "a.sh" }?.content == "a1")
    }

    /// A server holding no hooks is a normal state, and its answer must still decode —
    /// a fresh ccmuxd used to send `"files": null`, which the strict decode refuses, so
    /// every Mac's sync failed with an error it could never get past.
    @Test func aBundleWithNoFilesStillDecodes() throws {
        let empty = Data(#"{"apiVersion":1,"version":"abc","files":[]}"#.utf8)
        #expect(try JSONStore.decoder.decode(HookBundle.self, from: empty).files.isEmpty)
        // Absent or null still has to fail: it decides which executable files get deleted.
        for bad in [#"{"apiVersion":1,"version":"abc"}"#,
                    #"{"apiVersion":1,"version":"abc","files":null}"#] {
            #expect(throws: (any Error).self) {
                try JSONStore.decoder.decode(HookBundle.self, from: Data(bad.utf8))
            }
        }
    }

    @Test func theBaselineSurvivesARoundTrip() {
        let (_, baselineFile) = temp()
        defer { try? FileManager.default.removeItem(
            at: baselineFile.deletingLastPathComponent()) }
        // Whole seconds: JSONStore writes ISO-8601, which has no room for a fraction.
        // Nothing depends on the precision — the stamp is only ever displayed — but a
        // comparison against `Date()` would fail on the truncation alone.
        var original = baseline([file("a.sh", "one"), file("b/c.sh", "two")])
        original.syncedAt = Date(timeIntervalSince1970: 2)
        original.save(to: baselineFile)
        #expect(HookBaseline.load(from: baselineFile) == original)
    }
}

@Suite("Shell syntax")
struct ShellSyntaxTests {
    /// The one property that matters. Colouring is cosmetic; losing or duplicating a
    /// character in a script the user is reading to decide whether to publish it is not.
    @Test func theRunsAlwaysReassembleIntoTheInput() {
        for source in [
            "#!/bin/sh\nif [ -z \"$1\" ]; then echo 'hi #not a comment'; fi\n",
            "echo \"unterminated",
            "echo 'unterminated",
            "x=${FOO:-bar} # trailing\n",
            "printf '%s\\\\n' \"$@\"",
            "case $x in a) echo a;; esac",
            "echo \\\\\"escaped\\\\\" done",
            "", "\n\n", "тест # комментарий\n", "a#b ${x#y}",
        ] {
            #expect(ShellSyntax.highlight(source).map(\.text).joined() == source,
                    "mangled: \(source)")
        }
    }

    /// The same property over pseudo-random soup, since the shapes that break a hand-
    /// rolled scanner are the ones nobody thinks to write down: a quote opened at the end
    /// of the input, a backslash as the last character, `${` never closed.
    @Test func theRunsReassembleForGeneratedInputToo() {
        // Fixed seed: a losslessness failure has to be reproducible, not a one-off report.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        let alphabet = Array("abc #'\"\\$}{;|&()\n\t 1_éд")
        for _ in 0..<400 {
            let length = Int(next() % 40)
            let source = String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            #expect(ShellSyntax.highlight(source).map(\.text).joined() == source,
                    "mangled: \(source.debugDescription)")
        }
    }

    @Test func theObviousTokensAreRecognised() {
        let runs = ShellSyntax.highlight("if true; then echo \"$HOME\"; fi # done\n")
        #expect(runs.filter { $0.kind == .keyword }.map(\.text) == ["if", "then", "echo", "fi"])
        #expect(runs.contains { $0.kind == .comment && $0.text == "# done" })
        #expect(runs.contains { $0.kind == .string && $0.text == "\"$HOME\"" })
    }

    /// `a#b` is a word and `${x#y}` is a substitution; neither starts a comment, and
    /// treating either as one would grey out the rest of a working line.
    @Test func aHashInsideAWordIsNotAComment() {
        #expect(!ShellSyntax.highlight("foo#bar").contains { $0.kind == .comment })
        #expect(!ShellSyntax.highlight("echo ${x#y}").contains { $0.kind == .comment })
        #expect(ShellSyntax.highlight("foo # bar").contains { $0.kind == .comment })
    }

    /// A word that spells a keyword is only one where a command can start.
    @Test func aKeywordUsedAsAnArgumentStaysPlain() {
        let runs = ShellSyntax.highlight("grep done file")
        #expect(!runs.contains { $0.kind == .keyword && $0.text == "done" })
    }
}
