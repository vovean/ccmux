import Foundation

/// Decides when to nudge an account's 5-hour window into starting.
///
/// The window does not run on a fixed schedule: it starts on first use and resets five
/// hours later. Leave an account untouched overnight and the clock is simply stopped —
/// so sitting down at 09:00 means the window starts then and you wait until 14:00 for
/// the next one. Starting it while you are away keeps the cycle rolling, so by the time
/// you actually work the next boundary is closer.
///
/// The signal is `resetsAt == nil` rather than zero utilization: a window that has
/// started but is unused reports 0% *with* a reset time, and must not be probed again.
public enum WindowProbe {
    /// Not a rate limit so much as a guard against probing in a loop if an account ever
    /// reports no reset time after a successful probe.
    public static let minimumInterval: TimeInterval = 30 * 60

    public static func shouldProbe(account: Account, usage: UsageSnapshot?,
                                   lastProbe: Date?, now: Date = Date()) -> Bool {
        guard account.health != .needsRelogin else { return false }
        // Nothing known yet: a poll has to land first, or we cannot tell a stopped clock
        // from an unmeasured account.
        guard let usage, let session = usage.window(.session) else { return false }
        guard session.resetsAt == nil else { return false }
        if let lastProbe, now.timeIntervalSince(lastProbe) < minimumInterval { return false }
        return true
    }
}

extension UsageSnapshot {
    /// First window of a kind, for callers that only expect one.
    public func window(_ kind: UsageWindow.Kind) -> UsageWindow? {
        windows(kind: kind).first
    }
}
