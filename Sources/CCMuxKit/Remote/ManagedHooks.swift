import CCMuxCore
import Foundation

/// Writes the server's hook set into `~/.claude/hooks/managed`, and owns that directory
/// completely.
///
/// Owning it is what makes the sync converge: a file that has left the bundle is deleted
/// rather than left behind, so a hook withdrawn centrally stops running everywhere
/// instead of lingering on whichever Mac had it. Nothing outside that directory is ever
/// touched, and in particular `settings.json` is not — registering a hook is a deliberate,
/// user-visible act, not something a housekeeping tick does behind you.
///
/// Every path is validated here as well as on the server. The server is trusted with far
/// more than this already, but these files are executed rather than merely read, so a bug
/// there should not be able to write outside this directory.
public enum ManagedHooks {
    public static var root: URL {
        Paths.claudeHome
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("managed", isDirectory: true)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case rejectedPath(String, String)
        case write(String)

        public var errorDescription: String? {
            switch self {
            case .rejectedPath(let path, let why): return "refused hook path \(path): \(why)"
            case .write(let message): return message
            }
        }
    }

    // MARK: - Validation

    /// The same rules the server applies, restated rather than assumed.
    public static func validate(_ path: String) -> String? {
        if path.isEmpty { return "empty" }
        if path.count > 128 { return "too long" }
        if path.contains("\\") || path.contains("\0") { return "illegal character" }
        if path.hasPrefix("/") { return "must be relative" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count > 4 { return "nested too deeply" }
        for segment in segments {
            if segment.isEmpty { return "empty segment" }
            if segment == "." || segment == ".." { return "relative segment" }
            if segment.hasPrefix(".") { return "segment starts with a dot" }
            // The same narrow alphabet the server enforces. Anything outside it makes Go's
            // byte ordering and Swift's Unicode ordering disagree about how to sort the
            // bundle, and the two sides then hash it differently forever.
            if segment.contains(where: { !allowed.contains($0) }) {
                return "may only use letters, digits, dot, dash and underscore"
            }
        }
        return nil
    }

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz"
        + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    // MARK: - What is on disk

    /// The version of whatever is currently installed, computed the same way the server
    /// computes the bundle's.
    ///
    /// Derived from the files rather than remembered in a marker: a marker drifts the
    /// moment anyone edits a hook by hand or deletes the directory, and then the sync
    /// believes it is done while the Mac runs something else. Hashing what is actually
    /// there makes the whole thing self-healing.
    public static func installedVersion(in root: URL = ManagedHooks.root) -> String {
        version(of: onDisk(in: root))
    }

    static func onDisk(in root: URL = ManagedHooks.root) -> [HookFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey,
                                                                      .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [HookFile] = []
        let prefix = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // A symlink here is not ours and is not followed: it is reported as absent so
            // the next apply replaces it with a real file.
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix + "/") else { continue }
            let relative = String(full.dropFirst(prefix.count + 1))
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let mode = ((try? fm.attributesOfItem(atPath: full))?[.posixPermissions]
                as? Int) ?? 0
            found.append(HookFile(path: relative, content: content,
                                  executable: (mode & 0o100) != 0))
        }
        return found
    }

    /// Byte-for-byte the server's `hookVersion`: sorted by path, length-prefixed so a
    /// shifted boundary cannot collide, and the executable bit included because the same
    /// text at two modes is not the same install.
    public static func version(of files: [HookFile]) -> String {
        var buffer = Data()
        // Ordered by UTF-8 bytes, which is what Go's string comparison does. Swift's `<`
        // is Unicode collation and is not the same order; the paths are ASCII-only by
        // validation, but stating the ordering here means the two sides cannot drift.
        let ordered = files.sorted {
            Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8))
        }
        for file in ordered {
            let line = "\(file.path.utf8.count):\(file.path)\n"
                + "\(file.content.utf8.count):\(file.content)\n"
                + "\(file.executable)\n"
            buffer.append(Data(line.utf8))
        }
        return CryptoShim.sha256Hex(buffer)
    }

    // MARK: - Applying

    /// Installs the bundle by building the whole tree beside the live one and swapping.
    ///
    /// Staged rather than written in place, because in place there is no safe order. Write
    /// first and a bundle that renames `Fable.sh` to `fable.sh` has the prune delete the
    /// file it just wrote, since APFS is case-insensitive and the directory entry keeps its
    /// old name. Prune first and a failure halfway leaves the Mac with no hooks at all. A
    /// fresh tree has neither problem: it is built from nothing, so a path that is a file
    /// in one revision and a directory in the next cannot collide with its own past, and
    /// the swap is one atomic step with no window where the directory is missing.
    ///
    /// Everything is validated before anything is created, and nothing outside
    /// `~/.claude/hooks/managed` is touched.
    @discardableResult
    public static func apply(_ bundle: HookBundle,
                             into root: URL = ManagedHooks.root) throws
        -> (written: [String], removed: [String]) {
        for file in bundle.files {
            if let why = validate(file.path) { throw Failure.rejectedPath(file.path, why) }
        }
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.write("could not create \(parent.path): \(error.localizedDescription)")
        }
        sweepAbandonedStaging(in: parent, for: root.lastPathComponent)

        let staging = parent.appendingPathComponent(
            ".\(root.lastPathComponent)\(stagingMarker)\(UUID().uuidString)", isDirectory: true)
        // Covers both outcomes: on failure this is the half-built tree, and on success the
        // swap has already put the *old* tree here.
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.write("could not stage hooks: \(error.localizedDescription)")
        }

        for file in bundle.files {
            let target = staging.appendingPathComponent(file.path)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure.write("could not stage \(file.path): "
                    + error.localizedDescription)
            }
            guard fm.createFile(atPath: target.path, contents: Data(file.content.utf8),
                                attributes: [.posixPermissions:
                                                file.executable ? 0o700 : 0o600]) else {
                throw Failure.write("could not stage \(file.path)")
            }
        }

        let before = Set(onDisk(in: root).map(\.path))
        if fm.fileExists(atPath: root.path) {
            // One atomic step, so a hook invoked mid-sync sees the old tree or the new one
            // and never a missing directory. Afterwards `staging` holds the old tree and
            // the defer above deletes it.
            guard renamex_np(staging.path, root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.write("could not swap in the new hooks: "
                    + String(cString: strerror(errno)))
            }
        } else {
            guard rename(staging.path, root.path) == 0 else {
                throw Failure.write("could not install hooks: "
                    + String(cString: strerror(errno)))
            }
        }
        let kept = Set(bundle.files.map(\.path))
        return (written: bundle.files.map(\.path).sorted(),
                removed: before.subtracting(kept).sorted())
    }

    private static let stagingMarker = ".staging-"

    /// Clears trees left behind by a crash between staging and the swap. Without this they
    /// accumulate one per interruption, each holding executable files, and nothing ever
    /// looks at them again.
    private static func sweepAbandonedStaging(in parent: URL, for name: String) {
        let fm = FileManager.default
        let prefix = ".\(name)\(stagingMarker)"
        guard let entries = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(entry))
        }
    }
}
