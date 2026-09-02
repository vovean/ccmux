import CCMuxCore
import Foundation

/// What this Mac and the server last agreed on, per file — the third value that makes
/// "the server moved" distinguishable from "this Mac moved". The cost is deliberate: a
/// hook corrupted on disk now reads as an edit and stays until someone answers, where
/// hashing the directory alone used to heal it.
public struct HookBaseline: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var digest: String
        /// When this file's content arrived, not when the set was last checked.
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

    /// Records a file as agreed only when what landed on disk is what the server has:
    /// resolving one conflict keeps *other* undecided files local, and recording those
    /// would erase the edit nobody has answered for yet.
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
        case inSync
        /// The server moved and this Mac did not — also a file newly published, one
        /// withdrawn, and one deleted here by hand. Applied without asking.
        case stale
        /// This Mac moved and the server did not. Nothing is overwritten until answered.
        case editedHere
        case conflict
        /// The server has not been reached, so nothing can be said about this file.
        case unknown
    }

    public var path: String
    public var state: State
    public var local: HookFile?
    public var server: HookFile?
    public var syncedAt: Date?

    public var id: String { path }

    /// The whole sync waits while any of these are outstanding.
    public var needsDecision: Bool { state == .editedHere || state == .conflict }

    /// What is on this Mac, or the server's copy for a file that has not landed yet.
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
    /// When the set was last read — unlike a file's own `syncedAt`, this moves every tick.
    public var checkedAt: Date?
    public var serverVersion: String?

    /// Nothing is written to the managed directory until this clears: the apply builds
    /// the whole tree at once, so a stale file would take the undecided one with it.
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
    /// Compares three values per file: disk, the server, and what the two last agreed on.
    /// A nil `server` — offline, or a ccmuxd too old — is `unknown` rather than guessed
    /// at, since with no server copy "in sync" and "edited here" look identical.
    public static func classify(local: [HookFile], server: [HookFile]?,
                                baseline: HookBaseline?) -> [ManagedHook] {
        // A name the bundle rules refuse can never be published, so treating it as an edit
        // would hold the sync on a file no button could settle. Left out of the states
        // only — it still counts towards the installed version, so the next apply sweeps
        // it and says so, exactly as it did before there were states at all.
        let locals = index(local.filter { ManagedHooks.validate($0.path) == nil })
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

    public enum Failure: Error, LocalizedError, Equatable {
        case pathCollision(String, String)

        public var errorDescription: String? {
            switch self {
            case .pathCollision(let held, let other):
                return "\(held) and \(other) differ only in case, so this Mac cannot hold "
                    + "both. Settle \(held) first."
            }
        }
    }

    /// The tree to write when `path` is resolved in the server's favour, keeping every
    /// other still-undecided file as it is on this Mac.
    ///
    /// Refuses rather than writes when a retained file and a server file differ only in
    /// case: APFS folds them into one entry during staging, so one of the two would be
    /// silently lost.
    public static func treeTakingServer(_ path: String,
                                        in hooks: [ManagedHook]) throws -> [HookFile] {
        var tree: [HookFile] = []
        var claimed: [String: (path: String, held: Bool)] = [:]
        for hook in hooks {
            let keepLocal = hook.path != path && hook.needsDecision
            guard let file = keepLocal ? hook.local : hook.server else { continue }
            let key = file.path.lowercased()
            if let clash = claimed.updateValue((file.path, keepLocal), forKey: key) {
                // Named held-first: only a held file has buttons, so the other one is a
                // dead end to point the user at.
                throw keepLocal ? Failure.pathCollision(file.path, clash.path)
                                : Failure.pathCollision(clash.path, file.path)
            }
            tree.append(file)
        }
        return tree
    }

    /// The server's set with one file swapped in — not the whole local tree, though the
    /// route takes whole bundles, because that would publish every other unanswered edit.
    public static func bundlePublishing(_ path: String, in hooks: [ManagedHook]) -> [HookFile]? {
        guard let hook = hooks.first(where: { $0.path == path }), var mine = hook.local
        else { return nil }
        // Activation is the server's, not the file's: a copy read off disk defaults to
        // active, so publishing an edit would quietly re-register something turned off.
        mine.active = hook.server?.active ?? true
        var bundle = hooks.compactMap { $0.path == path ? nil : $0.server }
        bundle.append(mine)
        return bundle
    }

    @discardableResult
    private static func record(_ baseline: HookBaseline?, local: [HookFile],
                               server: [HookFile], to file: URL,
                               at now: Date) -> HookBaseline? {
        let advanced = HookBaseline.advance(baseline, applied: local, server: server, at: now)
        guard advanced != baseline else { return baseline }
        advanced.save(to: file)
        return advanced
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

    /// Writes the server's set in, but only when nothing is waiting on the user. All
    /// filesystem work: the caller runs it off the main actor.
    public static func reconcile(server: [HookFile], serverVersion: String,
                                 root: URL = ManagedHooks.root,
                                 baselineFile: URL = Paths.hookBaselineFile,
                                 now: Date = Date()) -> Reconciliation {
        let baseline = HookBaseline.load(from: baselineFile)
        let local = ManagedHooks.onDisk(in: root)
        // Classified against the baseline as loaded. Recording first would give a
        // first-ever run a non-empty baseline to compare against, and every file this Mac
        // had edited before upgrading would read as a conflict instead of taking the
        // server's copy.
        let hooks = classify(local: local, server: server, baseline: baseline)

        // A file already matching the server is agreed whether or not something else is
        // held, and a Mac that was in sync when this feature arrived never applies
        // anything — without recording here it would never get a baseline at all.
        guard hooks.contains(where: \.needsDecision) == false,
              ManagedHooks.version(of: local) != serverVersion else {
            let advanced = record(baseline, local: local, server: server,
                                  to: baselineFile, at: now)
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
