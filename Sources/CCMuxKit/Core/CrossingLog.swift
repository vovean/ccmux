import Foundation

/// Remembers which threshold crossings have already been announced.
///
/// A key carries the window's reset time, so the next period is a different key and
/// re-arms by itself — nothing has to be cleared for a warning to fire again after a
/// window turns over.
public final class CrossingLog {
    private var fired: [String: Date]
    private let lock = NSLock()
    private let url: URL?
    /// Keys are dropped oldest-first, which needs the timestamps: a Set could only have
    /// dropped an arbitrary half, including keys still live — which re-announces a
    /// crossing the user already saw.
    static let maxRecorded = 500

    public init(url: URL? = Paths.notifiedFile) {
        self.url = url
        if let url, let loaded = JSONStore.load([String: Date].self, from: url) {
            fired = loaded
        } else if let url, let keys = JSONStore.load([String].self, from: url) {
            // An earlier build stored bare keys with no timestamps. Treat them as
            // already announced so upgrading does not re-fire every live crossing.
            let now = Date()
            fired = Dictionary(uniqueKeysWithValues: keys.map { ($0, now) })
        } else {
            fired = [:]
        }
    }

    /// True the first time a key is seen, false afterwards.
    public func claim(_ key: String, now: Date = Date()) -> Bool {
        lock.lock()
        guard fired[key] == nil else {
            lock.unlock()
            return false
        }
        fired[key] = now
        if fired.count > Self.maxRecorded {
            let excess = fired.count - Self.maxRecorded / 2
            for stale in fired.sorted(by: { $0.value < $1.value }).prefix(excess) {
                fired.removeValue(forKey: stale.key)
            }
        }
        let snapshot = fired
        lock.unlock()
        if let url { JSONStore.save(snapshot, to: url) }
        return true
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return fired.count
    }
}
