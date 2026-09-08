import Foundation

/// Which bucket an instant falls in.
///
/// One copy, because it is the rule the whole design rests on: a Mac and the server have
/// to agree on where a minute starts, or a re-send lands somewhere new and is added
/// instead of replaced. Its own type rather than a method on either the ledger or the
/// chart, so neither has to depend on the other to floor a date.
public enum UsageGrid {
    public static func floor(_ date: Date, seconds: Int) -> Date? {
        guard seconds > 0 else { return nil }
        let width = Double(seconds)
        return Date(timeIntervalSince1970:
                        (date.timeIntervalSince1970 / width).rounded(.down) * width)
    }

    public static func minute(containing date: Date) -> Date {
        // Cannot fail: the width is a literal 60.
        floor(date, seconds: 60) ?? date
    }
}
