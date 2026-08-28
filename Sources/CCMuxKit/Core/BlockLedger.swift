import CCMuxCore
import Foundation

/// Which sessions cannot make progress, and why.
///
/// Pure bookkeeping, deliberately separate from `Engine`: every clear path here is a
/// place a stale red dot can survive, and `Engine` owns on-disk state that cannot be
/// stood up in a test.
public struct BlockLedger: Equatable {
    public struct Entry: Equatable, Identifiable {
        public enum Reason: Equatable {
            /// Auto-switch is off for this session, so ccmux will not move it.
            case pinned
            /// Auto-switch would have moved it, but no other account qualifies.
            case noneEligible
        }

        public var sessionID: String
        public var accountID: String
        /// The model that was refused. nil when it could not be identified, which makes
        /// the entry clear on any success rather than waiting for a match that never comes.
        public var model: String?
        public var reason: Reason
        public var since: Date

        public var id: String { sessionID }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(sessionID: String) -> Entry? { entries[sessionID] }

    /// Oldest first, so the UI orders by how long each has been stuck.
    public var all: [Entry] { entries.values.sorted { $0.since < $1.since } }

    /// Records the block. Returns true when it is new or materially different, which is
    /// the only time it is worth announcing — re-announcing on every refused request
    /// would re-raise a banner the user just dismissed.
    @discardableResult
    public mutating func block(sessionID: String, accountID: String, model: String?,
                               reason: Entry.Reason, now: Date = Date()) -> Bool {
        let known = entries[sessionID]
        entries[sessionID] = Entry(sessionID: sessionID, accountID: accountID,
                                   model: model, reason: reason,
                                   since: known?.since ?? now)
        guard let known else { return true }
        return known.accountID != accountID || known.reason != reason
            || known.model != model
    }

    @discardableResult
    public mutating func unblock(_ sessionID: String) -> Bool {
        entries.removeValue(forKey: sessionID) != nil
    }

    /// A request went through for this session. Clears the block when that actually means
    /// the session is unstuck.
    ///
    /// Matching the model matters: Claude Code issues auxiliary requests on cheaper
    /// models, and one of those succeeding says nothing about the model that was refused.
    @discardableResult
    public mutating func served(sessionID: String, accountID: String,
                                model: String?) -> Bool {
        guard let entry = entries[sessionID] else { return false }
        // Served by someone else means it moved — proxy-level failover reassigns without
        // going through the Engine, so this is the only signal that it happened.
        if entry.accountID != accountID { return unblock(sessionID) }
        guard let blocked = entry.model else { return unblock(sessionID) }
        guard blocked == model else { return false }
        return unblock(sessionID)
    }

    /// Drops entries for sessions that no longer exist. Returns what it dropped.
    @discardableResult
    public mutating func prune(liveSessionIDs: Set<String>) -> [String] {
        let stale = entries.keys.filter { !liveSessionIDs.contains($0) }
        for sessionID in stale { entries.removeValue(forKey: sessionID) }
        return stale
    }
}
