import Foundation

public enum UsageParser {
    /// Parses GET /api/oauth/usage. Prefers the `limits` array, which is the only
    /// place per-model weekly windows (e.g. Fable) appear; falls back to the older
    /// five_hour / seven_day keys when a response carries no `limits`.
    public static func windows(from json: [String: Any]) -> [UsageWindow] {
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            let parsed = limits.compactMap(window(fromLimit:))
            if !parsed.isEmpty { return parsed }
        }
        var result: [UsageWindow] = []
        if let w = legacyWindow(json["five_hour"], kind: .session, label: "5-hour") {
            result.append(w)
        }
        if let w = legacyWindow(json["seven_day"], kind: .weeklyAll, label: "Weekly") {
            result.append(w)
        }
        return result
    }

    static func window(fromLimit limit: [String: Any]) -> UsageWindow? {
        guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = date(limit["resets_at"])
        let scope = limit["scope"] as? [String: Any]
        let model = (scope?["model"] as? [String: Any])?["display_name"] as? String

        switch limit["kind"] as? String {
        case "session":
            return UsageWindow(kind: .session, label: "5-hour", percent: percent,
                               resetsAt: resetsAt)
        case "weekly_all":
            return UsageWindow(kind: .weeklyAll, label: "Weekly", percent: percent,
                               resetsAt: resetsAt)
        case "weekly_scoped":
            guard let model else { return nil }
            return UsageWindow(kind: .weeklyScoped, label: "Weekly \(model)",
                               percent: percent, resetsAt: resetsAt, modelName: model)
        case let other:
            let words = other?.replacingOccurrences(of: "_", with: " ") ?? "limit"
            return UsageWindow(kind: .other, label: words.uppercasingFirstLetter(),
                               percent: percent, resetsAt: resetsAt, modelName: model)
        }
    }

    static func legacyWindow(_ raw: Any?, kind: UsageWindow.Kind,
                             label: String) -> UsageWindow? {
        guard let dict = raw as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageWindow(kind: kind, label: label, percent: percent,
                           resetsAt: date(dict["resets_at"]))
    }

    /// The usage endpoint sends fractional seconds; the fallback covers a response
    /// without them. Cached because a parse allocated two of these per timestamp.
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO = ISO8601DateFormatter()

    static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return fractionalISO.date(from: text) ?? plainISO.date(from: text)
    }

    /// Reads the `anthropic-ratelimit-unified-*` response headers that ride along on
    /// every inference response. Free and exact for the 5-hour and weekly windows;
    /// per-model windows never appear here, so they still need the usage endpoint.
    /// Header names must already be lower-cased; `SessionProxy` does that once while
    /// it walks the response, rather than every reader rebuilding a folded copy.
    public static func windowsFromResponseHeaders(_ headers: [String: String])
        -> [UsageWindow] {
        func window(_ prefix: String, kind: UsageWindow.Kind, label: String) -> UsageWindow? {
            guard let raw = headers["anthropic-ratelimit-unified-\(prefix)-utilization"],
                  let fraction = Double(raw) else { return nil }
            let reset = headers["anthropic-ratelimit-unified-\(prefix)-reset"]
                .flatMap(Double.init)
                .map { Date(timeIntervalSince1970: $0) }
            // The header is a fraction of the limit (0.35 == 35%).
            return UsageWindow(kind: kind, label: label, percent: fraction * 100,
                               resetsAt: reset)
        }

        return [window("5h", kind: .session, label: "5-hour"),
                window("7d", kind: .weeklyAll, label: "Weekly")].compactMap { $0 }
    }

    /// True when the server says this request was refused for hitting a limit. Header
    /// names must already be lower-cased.
    public static func isRateLimited(headers: [String: String], statusCode: Int) -> Bool {
        statusCode == 429 || headers["anthropic-ratelimit-unified-status"] == "rejected"
    }
}


extension String {
    /// Sentence case, not title case: a window label reads as prose next to the
    /// hand-written ones ("Weekly Fable", "5-hour").
    func uppercasingFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
