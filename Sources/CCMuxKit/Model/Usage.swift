import Foundation

/// One rate-limit window as reported by the usage API or by response headers.
public struct UsageWindow: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, Equatable {
        case session          // the 5-hour window
        case weeklyAll        // weekly across all models
        case weeklyScoped     // weekly for one model, e.g. Fable
        case other
    }

    public var kind: Kind
    public var label: String
    public var percent: Double
    public var resetsAt: Date?
    public var modelName: String?

    public var id: String { "\(kind.rawValue)/\(modelName ?? label)" }
    public var headroom: Double { max(0, 100 - percent) }

    public init(kind: Kind, label: String, percent: Double,
                resetsAt: Date? = nil, modelName: String? = nil) {
        self.kind = kind
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.modelName = modelName
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    /// Set when the last fetch failed, so the UI can show stale-with-reason.
    public var lastError: String?
    public var nextPollAt: Date?
    public var pollInterval: TimeInterval?

    public init(windows: [UsageWindow] = [], fetchedAt: Date = Date(),
                lastError: String? = nil, nextPollAt: Date? = nil,
                pollInterval: TimeInterval? = nil) {
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.lastError = lastError
        self.nextPollAt = nextPollAt
        self.pollInterval = pollInterval
    }

    public func window(_ kind: UsageWindow.Kind, model: String? = nil) -> UsageWindow? {
        windows.first {
            guard $0.kind == kind else { return false }
            guard let model else { return true }
            return $0.modelName?.caseInsensitiveCompare(model) == .orderedSame
        }
    }

    /// Headroom on the binding window: the one closest to its limit.
    public var bindingHeadroom: Double? {
        windows.map(\.headroom).min()
    }
}
