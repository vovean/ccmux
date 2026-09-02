import CCMuxCore
import Foundation

/// What this Mac and the server last agreed on, per file.
///
/// The sync exists to converge on the server's set, and until now it did that by hashing
/// the managed directory and overwriting whenever the hash differed. That is
/// self-healing — a hook edited or truncated by hand is restored on the next tick — but
/// it cannot tell *which side* changed, so it treats a deliberate local edit exactly like
/// corruption and throws it away.
///
/// This is the third value that makes the two distinguishable. With it, "the server moved
/// and this Mac did not" stays automatic, and "this Mac moved" stops the sync and asks.
/// The cost is real and deliberate: a hook quietly corrupted on disk is now an edit, and
/// it stays corrupted until someone answers the question on the Hooks page.
///
/// One case keeps the old behaviour on purpose. A file that has been *deleted* locally is
/// restored without asking. Deleting a hook is almost never a considered edit, and the
/// failure mode is invisible — the hook simply never runs again, with nothing to notice.
/// Withdrawing a hook is done on the server, where it takes effect on every Mac.
public struct HookBaseline: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var digest: String
        /// When this file's current content arrived, not when the set was last checked:
        /// a hook untouched for a month should say so rather than claim it synced a
        /// minute ago.
        public var syncedAt: Date

        public init(digest: String, syncedAt: Date) {
            self.digest = digest
            self.syncedAt = syncedAt
        }
    }

    public var files: [String: Entry]
    public var syncedAt: Date

    public init(files: [String: Entry] = [:], syncedAt: Date = Date()) {
        self.files = files
        self.syncedAt = syncedAt
    }

    public static func load(from url: URL = Paths.hookBaselineFile) -> HookBaseline? {
        JSONStore.load(HookBaseline.self, from: url)
    }

    public func save(to url: URL = Paths.hookBaselineFile) {
        JSONStore.save(self, to: url)
    }

    /// The baseline after writing `tree` to disk, given what the server currently holds.
    ///
    /// A file is only recorded as agreed when what landed on disk is what the server has.
    /// Resolving one conflict writes a tree that deliberately keeps *other* undecided
    /// files as they are on this Mac; recording those as agreed would erase the very edit
    /// the user has not answered for yet.
    public static func advance(_ previous: HookBaseline?, applied tree: [HookFile],
                               server: [HookFile], at now: Date = Date()) -> HookBaseline {
        let serverDigests = Dictionary(server.map { ($0.path, ManagedHooks.digest(of: $0)) },
                                       uniquingKeysWith: { first, _ in first })
        var entries: [String: Entry] = [:]
        for file in tree {
            let digest = ManagedHooks.digest(of: file)
            guard serverDigests[file.path] == digest else {
                // Kept local against the server's copy: carry the old base forward so the
                // file still reads as edited here.
                entries[file.path] = previous?.files[file.path]
                continue
            }
            let unchanged = previous?.files[file.path]?.digest == digest
            entries[file.path] = Entry(digest: digest,
                                       syncedAt: unchanged
                                           ? (previous?.files[file.path]?.syncedAt ?? now)
                                           : now)
        }
        // Only moves when something actually landed, so "last synced" means the set last
        // changed here rather than the tick last ran.
        let unchanged = entries == previous?.files
        return HookBaseline(files: entries,
                            syncedAt: unchanged ? (previous?.syncedAt ?? now) : now)
    }
}

/// One managed hook, as the Hooks page sees it.
public struct ManagedHook: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// This Mac has exactly what the server has.
        case inSync
        /// The server moved and this Mac did not — including a file the server has just
        /// added, one it has withdrawn, and one deleted here by hand. Applied without
        /// asking.
        case stale
        /// This Mac moved and the server did not. Nothing is overwritten until answered.
        case editedHere
        /// Both moved, to different content.
        case conflict
        /// The server has not been reached yet, so nothing can be said about this file.
        case unknown
    }

    public var path: String
    public var state: State
    public var local: HookFile?
    public var server: HookFile?
    public var syncedAt: Date?

    public var id: String { path }

    /// Only the user can settle these, and the whole sync waits while any are outstanding.
    public var needsDecision: Bool { state == .editedHere || state == .conflict }

    /// The content to show: what is on this Mac, or the server's copy for a file that has
    /// not landed yet.
    public var body: String? { local?.content ?? server?.content }

    public init(path: String, state: State, local: HookFile? = nil,
                server: HookFile? = nil, syncedAt: Date? = nil) {
        self.path = path
        self.state = state
        self.local = local
        self.server = server
        self.syncedAt = syncedAt
    }
}

public enum HookResolution: String, Equatable, Sendable {
    /// Overwrite this Mac's copy with the server's.
    case takeServer
    /// Publish this Mac's copy to the server.
    case takeLocal
}

/// The whole managed set and what the sync may do with it.
public struct HookStatus: Equatable, Sendable {
    public var hooks: [ManagedHook] = []
    /// When the server's set was last read. Distinct from a file's own `syncedAt`: this
    /// moves on every tick, a file's only when its content does.
    public var checkedAt: Date?
    public var serverVersion: String?

    /// True while at least one file is waiting on the user. Nothing is written to the
    /// managed directory until it clears — the apply builds the whole tree at once, so
    /// letting a stale file through would take the undecided one with it.
    public var frozen: Bool { hooks.contains(where: \.needsDecision) }

    public var undecided: [ManagedHook] { hooks.filter(\.needsDecision) }

    public init(hooks: [ManagedHook] = [], checkedAt: Date? = nil,
                serverVersion: String? = nil) {
        self.hooks = hooks
        self.checkedAt = checkedAt
        self.serverVersion = serverVersion
    }
}

public enum HookSync {
    /// Sorts each file into one of the five states by comparing three values: what is on
    /// disk, what the server holds, and what the two last agreed on.
    ///
    /// `server` is nil when the set has not been fetched — offline, or a ccmuxd too old to
    /// serve hooks. That is reported as `unknown` rather than guessed at: with no server
    /// copy, "in sync" and "edited here" look identical.
    public static func classify(local: [HookFile], server: [HookFile]?,
                                baseline: HookBaseline?) -> [ManagedHook] {
        let locals = index(local)
        guard let server else {
            return locals.keys.sorted().map {
                ManagedHook(path: $0, state: .unknown, local: locals[$0],
                            syncedAt: baseline?.files[$0]?.syncedAt)
            }
        }
        let servers = index(server)

        return Set(locals.keys).union(servers.keys).sorted().map { path in
            let mine = locals[path]
            let theirs = servers[path]
            let base = baseline?.files[path]?.digest
            let hook = { (state: ManagedHook.State) in
                ManagedHook(path: path, state: state, local: mine, server: theirs,
                            syncedAt: baseline?.files[path]?.syncedAt)
            }

            if let mine, let theirs,
               ManagedHooks.digest(of: mine) == ManagedHooks.digest(of: theirs) {
                return hook(.inSync)
            }
            // No baseline at all is the first tick after upgrading, and the only honest
            // answer is the one this sync has always given: the server is right. Asking
            // instead would freeze every Mac on contents it has never disagreed about.
            guard baseline != nil else { return hook(.stale) }
            // Absent here — deleted by hand, or newly published and not yet written.
            guard let mine else { return hook(.stale) }

            let mineDigest = ManagedHooks.digest(of: mine)
            // Neither the server nor the last agreement has ever seen this path, so it was
            // written here. Reporting it stale would delete it on the next tick, which is
            // exactly what the old sync did to anything dropped into the directory.
            if theirs == nil, base == nil { return hook(.editedHere) }
            if mineDigest == base { return hook(.stale) }
            if theirs.map(ManagedHooks.digest(of:)) == base { return hook(.editedHere) }
            return hook(.conflict)
        }
    }

    /// The tree to write when `path` is resolved in the server's favour.
    ///
    /// Every other file still awaiting a decision keeps what is on this Mac. The apply is
    /// whole-tree and atomic, so answering one question must not silently answer the rest.
    public static func treeTakingServer(_ path: String, in hooks: [ManagedHook]) -> [HookFile] {
        var tree: [HookFile] = []
        for hook in hooks {
            if hook.path != path, hook.needsDecision, let local = hook.local {
                tree.append(local)
                continue
            }
            if let server = hook.server { tree.append(server) }
        }
        return tree
    }

    /// The bundle to publish when `path` is resolved in this Mac's favour: the server's
    /// set with that one file swapped in.
    ///
    /// Not the whole local tree, though the route takes whole bundles. Pushing the tree
    /// would publish every other unanswered edit along with the one the user actually
    /// clicked.
    public static func bundlePublishing(_ path: String, in hooks: [ManagedHook]) -> [HookFile]? {
        guard let mine = hooks.first(where: { $0.path == path })?.local else { return nil }
        var bundle = hooks.compactMap { $0.path == path ? nil : $0.server }
        bundle.append(mine)
        return bundle
    }

    private static func index(_ files: [HookFile]) -> [String: HookFile] {
        Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Writing

    public struct Reconciliation: Sendable, Equatable {
        public var hooks: [ManagedHook] = []
        public var written: [String] = []
        public var removed: [String] = []
        public var applied = false
        public var failure: String?
    }

    /// Reads the managed directory, sorts it against the server's set, and writes the
    /// server's copy in — but only when nothing is waiting on the user.
    ///
    /// All of it is filesystem work: the caller runs it off the main actor.
    public static func reconcile(server: [HookFile], serverVersion: String,
                                 root: URL = ManagedHooks.root,
                                 baselineFile: URL = Paths.hookBaselineFile,
                                 now: Date = Date()) -> Reconciliation {
        let baseline = HookBaseline.load(from: baselineFile)
        let local = ManagedHooks.onDisk(in: root)
        let hooks = classify(local: local, server: server, baseline: baseline)
        guard !hooks.contains(where: \.needsDecision) else { return Reconciliation(hooks: hooks) }

        // Already right: nothing to write, but the agreement still has to be recorded.
        // A Mac that was in sync at the moment this feature arrived would otherwise never
        // get a baseline at all, and every edit it ever made would read as corruption.
        guard ManagedHooks.version(of: local) != serverVersion else {
            let advanced = HookBaseline.advance(baseline, applied: local, server: server,
                                                at: now)
            if advanced != baseline { advanced.save(to: baselineFile) }
            return Reconciliation(hooks: classify(local: local, server: server,
                                                  baseline: advanced))
        }

        do {
            let result = try install(server, server: server, root: root,
                                     baselineFile: baselineFile, now: now)
            return Reconciliation(hooks: result.hooks, written: result.written,
                                  removed: result.removed, applied: true)
        } catch {
            return Reconciliation(hooks: hooks, failure: error.localizedDescription)
        }
    }

    /// Writes `tree` as one atomic swap and records the agreement it implies.
    @discardableResult
    public static func install(_ tree: [HookFile], server: [HookFile],
                               root: URL = ManagedHooks.root,
                               baselineFile: URL = Paths.hookBaselineFile,
                               now: Date = Date()) throws
        -> (written: [String], removed: [String], hooks: [ManagedHook]) {
        let previous = HookBaseline.load(from: baselineFile)
        let change = try ManagedHooks.apply(
            HookBundle(version: ManagedHooks.version(of: tree), files: tree), into: root)
        let advanced = HookBaseline.advance(previous, applied: tree, server: server, at: now)
        advanced.save(to: baselineFile)
        return (change.written, change.removed,
                classify(local: tree, server: server, baseline: advanced))
    }
}
