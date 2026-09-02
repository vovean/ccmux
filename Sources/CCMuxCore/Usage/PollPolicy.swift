import Foundation

/// Cadence for GET /api/oauth/usage.
///
/// The endpoint budgets roughly 28-30 requests per rolling hour per access token, and
/// capacity only returns as old requests age out — a burst saturates the token for up
/// to an hour, so pausing does not buy headroom back. These constants target ~20
/// requests/hour and leave room for manual refreshes. Measured by claude-swap
/// (poll_policy.py, 2026-07-11); re-measure before loosening any of them.
public enum PollPolicy {
    /// An entry younger than this is served from the store with no fetch at all, so
    /// the sustained rate per token is bounded no matter how many views are open.
    public static let serveTTL: TimeInterval = 180
    public static let minInterval: TimeInterval = 180
    /// Used only for an account near a threshold whose usage is actually moving.
    public static let urgentInterval: TimeInterval = 60
    public static let activeMaxInterval: TimeInterval = 300
    public static let idleMaxInterval: TimeInterval = 600
    public static let movementDeltaPercent: Double = 1
    public static let jitterFraction: Double = 0.1
    public static let rateLimitedBackoff: TimeInterval = 300
    public static let escalationMarginPercent: Double = 15
    /// Minimum spacing between manual refreshes, so the Refresh button cannot be
    /// mashed into the endpoint's hourly budget.
    public static let forcedPollFloor: TimeInterval = 60

    public struct Plan: Equatable {
        public var interval: TimeInterval
        public var nextPollAt: Date
    }

    public static func plan(isInUse: Bool, previous: UsageSnapshot?, current: UsageSnapshot,
                           threshold: Double, rateLimited: Bool = false,
                           now: Date = Date()) -> Plan {
        if rateLimited {
            return Plan(interval: rateLimitedBackoff,
                        nextPollAt: now.addingTimeInterval(jitter(rateLimitedBackoff)))
        }

        let moved = movement(from: previous, to: current) >= movementDeltaPercent
        let headroom = current.bindingHeadroom ?? 100
        let nearThreshold = headroom <= threshold + escalationMarginPercent

        var interval: TimeInterval
        if isInUse && nearThreshold && moved {
            interval = urgentInterval
        } else if isInUse {
            interval = moved ? minInterval : activeMaxInterval
        } else {
            interval = moved ? activeMaxInterval : idleMaxInterval
        }
        // A window resetting soon is worth one prompt poll just after it turns over.
        if let soonest = current.windows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
            let untilReset = soonest.timeIntervalSince(now) + 60
            if untilReset < interval { interval = max(untilReset, urgentInterval) }
        }

        return Plan(interval: interval, nextPollAt: now.addingTimeInterval(jitter(interval)))
    }

    /// Whether to ask the server again for a delegated account's usage.
    ///
    /// Counted from when this Mac last asked. Not from `fetchedAt`, which every proxied
    /// response pushes forward from headers that never carry the per-model windows — an
    /// account with a live session would then never be re-read at all. And not from the
    /// answer's own age either: the server caches each account for minutes, so that
    /// clears this floor on every tick.
    public static func shouldAskServer(lastAsked: Date?, now: Date = Date()) -> Bool {
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= serveTTL
    }

    static func movement(from previous: UsageSnapshot?, to current: UsageSnapshot) -> Double {
        guard let previous else { return .infinity }
        var delta: Double = 0
        for window in current.windows {
            let before = previous.windows.first { $0.id == window.id }?.percent ?? 0
            delta = max(delta, abs(window.percent - before))
        }
        return delta
    }

    static func jitter(_ interval: TimeInterval) -> TimeInterval {
        let spread = interval * jitterFraction
        return interval + Double.random(in: -spread...spread)
    }
}
