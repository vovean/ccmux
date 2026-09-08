import CCMuxCore
import Foundation

/// Token counts, minute by minute, on their way to the account server.
///
/// A minute is held open while it is still running and handed over only once it has
/// ended. That is what makes a bucket immutable the moment it leaves this Mac, which in
/// turn is what lets the server upsert a re-send instead of adding it twice — the whole
/// retry story rests on it.
///
/// Which is also why a quit does not flush the open minute: an upgrade restarts the app
/// while its sessions keep running, and a half-minute sent early would be replaced by the
/// half recorded after the restart rather than added to it. The open minutes go to the
/// spool alongside the closed ones and come back still open.
public struct UsageLedger: Equatable {
    /// The account belongs in the key, not in the bucket's payload. ccmux moves a session
    /// to another account when one is refused, and that happens mid-minute on the same
    /// model — so without it the whole minute would be booked to whichever account
    /// happened to serve last.
    struct Slot: Hashable {
        var minute: Date
        var sessionID: String
        var accountID: String
        var model: String
    }

    /// Bytes, not characters, and stricter than the server's own 256-rune ceiling on
    /// purpose: a request is capped in bytes, and 256 characters of Cyrillic or one
    /// emoji-heavy label is several times its length in UTF-8.
    public static let maxFieldBytes = 256

    static func clamp(_ value: String) -> String {
        guard value.utf8.count > maxFieldBytes else { return value }
        var out = ""
        var bytes = 0
        for character in value {
            let width = String(character).utf8.count
            if bytes + width > maxFieldBytes { break }
            out.append(character)
            bytes += width
        }
        return out
    }

    /// Everything a bucket needs to name itself, read once per request from state that
    /// disappears when the session ends.
    public struct Identity: Equatable, Sendable {
        public var sessionID: String
        public var sessionName: String
        public var accountID: String
        public var accountFingerprint: String?
        public var accountLabel: String
        public var kind: AccountKind
        public var model: String

        public init(sessionID: String, sessionName: String, accountID: String,
                    accountFingerprint: String? = nil, accountLabel: String,
                    kind: AccountKind, model: String) {
            self.sessionID = sessionID
            self.sessionName = sessionName
            self.accountID = accountID
            self.accountFingerprint = accountFingerprint
            self.accountLabel = accountLabel
            self.kind = kind
            self.model = model
        }
    }

    private var open: [Slot: UsageBucket] = [:]
    /// Closed minutes waiting for a server that will take them, oldest first — every
    /// batch closes minutes strictly later than the last one did. Appended to and drained
    /// from the front, so the prefix a push carried away is exactly what an acknowledged
    /// push removes.
    public private(set) var pending: [UsageBucket] = []
    /// Set by every mutation and cleared by `takeSpool`, so a tick that changed nothing
    /// does not rewrite the file.
    private var isDirty = false

    /// Past this the oldest go. A Mac that has not reached the server in days is not
    /// going to be caught up by keeping more, and this is what bounds the spool file.
    public static let maxPending = 10_000

    /// A ceiling on the buckets in one push, so a backlog drains over several ticks
    /// rather than being refused on every one of them forever.
    public static let maxPerPush = 400

    /// And a ceiling on its encoded size, which is what the server actually bounds:
    /// `decodeBody` caps a request at 1 MiB. Counting buckets is not enough — the fields
    /// inside one are user-supplied, so the only honest bound is the measured length.
    public static let maxPushBytes = 512 * 1024

    /// The front of the queue, bounded for one request.
    public var batch: [UsageBucket] {
        Self.fit(Array(pending.prefix(Self.maxPerPush)), within: Self.maxPushBytes)
    }

    /// Halves the batch until it encodes small enough. One bucket always goes, however
    /// big: refusing to send it would wedge the queue behind it forever.
    static func fit(_ buckets: [UsageBucket], within budget: Int) -> [UsageBucket] {
        var out = buckets
        while out.count > 1, encodedSize(out) > budget {
            out = Array(out.prefix(out.count / 2))
        }
        return out
    }

    static func encodedSize(_ buckets: [UsageBucket]) -> Int {
        (try? JSONStore.encoder.encode(buckets).count) ?? .max
    }

    public init() {}

    public static func minute(containing date: Date) -> Date {
        UsageGrid.minute(containing: date)
    }

    /// Folds one request into the minute it landed in.
    ///
    /// Priced here rather than at send time so a later edit to the price table cannot
    /// rewrite what something already cost. Unlike `Engine.recordSpend` this runs for
    /// every account, subscription included — those pay in quota rather than dollars, and
    /// the page says as much.
    public mutating func record(_ usage: TokenUsage, identity: Identity,
                                at date: Date = Date()) {
        let slot = Slot(minute: Self.minute(containing: date),
                        sessionID: Self.clamp(identity.sessionID),
                        accountID: Self.clamp(identity.accountID),
                        model: Self.clamp(identity.model))
        var bucket = open[slot] ?? UsageBucket(minute: slot.minute,
                                               sessionID: slot.sessionID,
                                               sessionName: identity.sessionName,
                                               accountID: slot.accountID,
                                               accountLabel: identity.accountLabel,
                                               model: slot.model)
        // Refreshed on every request: a session renamed mid-minute should carry its new
        // name, and the server takes the newest bucket's identity for the whole line.
        bucket.sessionName = Self.clamp(identity.sessionName)
        bucket.accountFingerprint = identity.accountFingerprint.map(Self.clamp)
        bucket.accountLabel = Self.clamp(identity.accountLabel)
        bucket.kind = identity.kind

        bucket.requests += 1
        bucket.input += usage.input
        bucket.output += usage.output
        bucket.cacheRead += usage.cacheRead
        bucket.cacheWrite5m += usage.cacheWrite5m
        bucket.cacheWrite1h += usage.cacheWrite1h
        // The model is part of the slot, so every request in one bucket prices the same
        // way: either they all carry a cost or none of them do.
        if let cost = Pricing.cost(model: slot.model, usage: usage, on: date) {
            bucket.costUSD = (bucket.costUSD ?? 0) + cost
        } else {
            bucket.costUSD = nil
        }
        open[slot] = bucket
        isDirty = true
    }

    /// Moves every minute that has ended into the queue.
    @discardableResult
    public mutating func closeElapsed(now: Date = Date()) -> Int {
        let boundary = Self.minute(containing: now)
        // Sorted, because a dictionary has no order and the queue is drained from the
        // front: without this the ceiling below would throw away an arbitrary bucket
        // instead of the oldest one.
        let done = open.keys.filter { $0.minute < boundary }
            .sorted { $0.minute < $1.minute }
        guard !done.isEmpty else { return 0 }
        for slot in done {
            if let bucket = open.removeValue(forKey: slot) { pending.append(bucket) }
        }
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
        isDirty = true
        return done.count
    }

    /// Drops the buckets a push carried away, by identity.
    ///
    /// Not by count: the queue is trimmed from the front when it hits its ceiling, and a
    /// push over a slow link outlives a tick — so a count taken before the push can name
    /// buckets that were never sent, and acknowledging it would delete them unsent.
    public mutating func acknowledge(_ sent: [UsageBucket]) {
        guard !sent.isEmpty else { return }
        let done = Set(sent.map(Self.slot(of:)))
        let before = pending.count
        pending.removeAll { done.contains(Self.slot(of: $0)) }
        if pending.count != before { isDirty = true }
    }

    static func slot(of bucket: UsageBucket) -> Slot {
        Slot(minute: bucket.minute, sessionID: bucket.sessionID,
             accountID: bucket.accountID, model: bucket.model)
    }

    public mutating func clear() {
        guard !open.isEmpty || !pending.isEmpty else { return }
        open = [:]
        pending = []
        isDirty = true
    }

    /// What to write, or nil when nothing has changed since the last write.
    ///
    /// One member rather than a flag and a separate clear: those two had to be used
    /// together in one exact order, and the order that skips the write is the one that
    /// loses the spool on quit.
    public mutating func takeSpool() -> Spool? {
        guard isDirty else { return nil }
        isDirty = false
        return spool
    }

    // MARK: - Spool

    /// What survives a quit. Open minutes are carried as open, so an upgrade that restarts
    /// the app mid-minute resumes the same bucket rather than starting a second one that
    /// would replace it.
    public struct Spool: Codable, Equatable, Sendable {
        public var open: [UsageBucket]
        public var pending: [UsageBucket]

        public init(open: [UsageBucket] = [], pending: [UsageBucket] = []) {
            self.open = open
            self.pending = pending
        }
    }

    var spool: Spool { Spool(open: Array(open.values), pending: pending) }

    public init(_ spool: Spool) {
        for bucket in spool.open { open[Self.slot(of: bucket)] = bucket }
        // Re-sorted rather than trusted: the file may have been written by a build whose
        // queue was not ordered, and the ceiling below drops from the front.
        pending = spool.pending.sorted { $0.minute < $1.minute }
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
    }
}
