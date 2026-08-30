import CCMuxCore
import Foundation

public enum Format {
    /// Formatters are expensive to build (~24 us each) and these run per window per
    /// render, so they are built once.
    private static let sameDayClock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let otherDayClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d jm")
        return f
    }()

    /// Absolute time, in the viewer's 12/24-hour setting: "23:30" today, "Aug 25 10:00"
    /// otherwise.
    public static func clock(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? sameDayClock.string(from: date)
            : otherDayClock.string(from: date)
    }

    /// `now` is injectable so a caller — or a test — gets the same answer for the same
    /// pair of instants rather than one that drifts by whatever time elapsed.
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// A century, past which every span reads the same anyway.
    static let maxDisplayableSeconds: TimeInterval = 100 * 365 * 24 * 3600

    /// An elapsed span, coarsened the way people read one: seconds only under a minute,
    /// then minutes, then hours. Used for how long ago something happened, where the
    /// difference between 4m12s and 4m is worth nothing.
    public static func duration(_ seconds: TimeInterval) -> String {
        // Clamped before the conversion, which traps: `Int(Double)` fatal-errors on NaN
        // and on anything past Int.max, and this formats ages that arrive over the wire
        // as bare float64. A crash inside a SwiftUI view body takes the window with it.
        let total = Int(min(max(0, seconds.rounded()), maxDisplayableSeconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }

    public static func shortenHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

public extension Format {
    /// Sub-cent amounts still matter when a single cheap request is the whole story, so
    /// small numbers keep more places rather than collapsing to "$0.00".
    static func money(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        if usd < 1 { return String(format: "$%.3f", usd) }
        return String(format: "$%.2f", usd)
    }
}
