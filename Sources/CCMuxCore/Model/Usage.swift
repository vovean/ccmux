import Foundation

/// One rate-limit window as reported by the usage API or by response headers.
public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Equatable, CaseIterable, Sendable {
        case session          // the 5-hour window
        case weeklyAll        // weekly across all models
        case weeklyScoped     // weekly for one model, e.g. Fable
        // API-key accounts report per-minute ceilings instead of subscription quota.
        case apiRequests
        case apiTokens
        case apiInputTokens
        case apiOutputTokens
        /// Not a server limit at all — spend against the monthly budget, drawn as a bar
        /// so money reads the same way every other ceiling does.
        case budget
        case other

        public var displayName: String {
            switch self {
            case .session: return "5-hour window"
            case .weeklyAll: return "Weekly (all models)"
            case .weeklyScoped: return "Weekly (per model, e.g. Fable)"
            case .apiRequests: return "API requests per minute"
            case .apiTokens: return "API tokens per minute"
            case .apiInputTokens: return "API input tokens per minute"
            case .apiOutputTokens: return "API output tokens per minute"
            case .budget: return "Monthly spend"
            case .other: return "Other windows"
            }
        }

        /// The kinds a threshold warning can be asked to watch. `.other` is whatever a
        /// future API version adds and has no meaning to configure yet.
        public static let watchable: [Kind] = [.session, .weeklyAll, .weeklyScoped]
    }

    public var kind: Kind
    public var label: String
    public var percent: Double
    public var resetsAt: Date?
    public var modelName: String?

    public var id: String { "\(kind.rawValue)/\(modelName ?? label)" }

    /// A per-minute ceiling refills continuously, so it says nothing about whether an
    /// account is worth choosing — only whether a request would be throttled right now.
    public var isPerMinute: Bool {
        switch kind {
        case .apiRequests, .apiTokens, .apiInputTokens, .apiOutputTokens: return true
        default: return false
        }
    }
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

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    /// When any source last updated these numbers, including a proxied response header.
    public var fetchedAt: Date
    /// When GET /api/oauth/usage last succeeded. Tracked separately from `fetchedAt`
    /// because response headers refresh the 5-hour and weekly windows but never the
    /// per-model ones — scheduling polls off `fetchedAt` would let an active session
    /// suppress the endpoint forever and freeze the Fable window.
    public var lastEndpointFetchAt: Date?
    /// Set when the last fetch failed, so the UI can show stale-with-reason.
    public var lastError: String?
    public var nextPollAt: Date?

    public init(windows: [UsageWindow] = [], fetchedAt: Date = Date(),
                lastEndpointFetchAt: Date? = nil, lastError: String? = nil,
                nextPollAt: Date? = nil) {
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.lastEndpointFetchAt = lastEndpointFetchAt
        self.lastError = lastError
        self.nextPollAt = nextPollAt
    }

    /// Windows of a kind, optionally narrowed to one model. The model filter only
    /// applies to per-model windows, so `.session` is never filtered out by it.
    public func windows(kind: UsageWindow.Kind, model: String? = nil) -> [UsageWindow] {
        windows.filter { window in
            guard window.kind == kind else { return false }
            guard kind == .weeklyScoped, let model else { return true }
            return window.modelName?.caseInsensitiveCompare(model) == .orderedSame
        }
    }

    /// Headroom on the binding window: the one closest to its limit.
    public var bindingHeadroom: Double? {
        windows.map(\.headroom).min()
    }
}
