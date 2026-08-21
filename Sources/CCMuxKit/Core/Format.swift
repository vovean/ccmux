import Foundation

public enum Format {
    /// Absolute time: "23:30" today, "Aug 25 10:00" otherwise.
    public static func clock(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now)
            ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
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

    public static func shortenHome(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
