import Foundation

/// A launch policy: what an alias like `cc-fable` requires of an account.
public struct Policy: Codable, Equatable, Identifiable {
    public var name: String
    /// Windows the policy cares about. A window not listed is ignored when ranking, so
    /// `opus` can pick an account whose Fable weekly is exhausted.
    public var requiredWindows: [UsageWindow.Kind]
    /// For `weeklyScoped`, which model's window. nil means every scoped window.
    public var scopedModel: String?
    /// Minimum headroom per window kind for an account to be picked **at launch**,
    /// keyed by `UsageWindow.Kind.rawValue` so the settings file stays hand-editable.
    ///
    /// Launch only: a session already running takes whatever can still serve it, because
    /// refusing a usable account mid-task parks the session when the alternative is a few
    /// more useful requests. A window with no entry has no floor beyond being non-zero.
    public var launchFloors: [String: Double]

    public var id: String { name }

    public init(name: String, requiredWindows: [UsageWindow.Kind],
                scopedModel: String? = nil, launchFloors: [String: Double] = [:]) {
        self.name = name
        self.requiredWindows = requiredWindows
        self.scopedModel = scopedModel
        self.launchFloors = launchFloors
    }

    public func floor(for kind: UsageWindow.Kind) -> Double {
        launchFloors[kind.rawValue] ?? 0
    }

    /// Fable needs more room to be worth starting on than Opus: its own weekly window is
    /// the scarce one, and a Fable session that starts on scraps spends them re-reading
    /// its context after the first failover.
    public static let defaults: [Policy] = [
        Policy(name: "opus", requiredWindows: [.session, .weeklyAll],
               launchFloors: ["session": 3, "weeklyAll": 1]),
        Policy(name: "fable", requiredWindows: [.session, .weeklyAll, .weeklyScoped],
               scopedModel: "Fable",
               launchFloors: ["session": 5, "weeklyAll": 3, "weeklyScoped": 3]),
        Policy(name: "any", requiredWindows: [.session, .weeklyAll],
               launchFloors: ["session": 3, "weeklyAll": 1]),
    ]
}

public enum AutoSwitchMode: String, Codable, Equatable, CaseIterable {
    case off
    case immediate
    case atTurnBoundary

    public var label: String {
        switch self {
        case .off: return "Off"
        case .immediate: return "Immediately"
        case .atTurnBoundary: return "At turn boundary"
        }
    }
}

public struct Settings: Codable, Equatable {
    public var warnThresholdPercent: Double
    public var watchedWindows: [UsageWindow.Kind]
    public var autoSwitch: AutoSwitchMode
    public var policies: [Policy]
    public var notifyOnAutoSwitch: Bool
    public var notifyOnReloginNeeded: Bool
    public var mutedAccountIDs: [String]
    /// Start each account's 5-hour window as soon as it is idle, so the cycle keeps
    /// rolling while you are away and less of it is left to wait out when you return.
    public var keepWindowsRolling: Bool

    public init(warnThresholdPercent: Double = 3,
                watchedWindows: [UsageWindow.Kind] = [.session, .weeklyAll, .weeklyScoped],
                autoSwitch: AutoSwitchMode = .immediate,
                policies: [Policy] = Policy.defaults,
                notifyOnAutoSwitch: Bool = true,
                notifyOnReloginNeeded: Bool = true,
                mutedAccountIDs: [String] = [],
                keepWindowsRolling: Bool = true) {
        self.warnThresholdPercent = warnThresholdPercent
        self.watchedWindows = watchedWindows
        self.autoSwitch = autoSwitch
        self.policies = policies
        self.notifyOnAutoSwitch = notifyOnAutoSwitch
        self.notifyOnReloginNeeded = notifyOnReloginNeeded
        self.mutedAccountIDs = mutedAccountIDs
        self.keepWindowsRolling = keepWindowsRolling
    }

    /// Adds or removes a watched window without letting duplicates into persisted
    /// state, which a containment-check in the UI was the only thing preventing.
    public mutating func setWatched(_ kind: UsageWindow.Kind, on: Bool) {
        watchedWindows.removeAll { $0 == kind }
        if on { watchedWindows.append(kind) }
    }

    public func policy(named name: String) -> Policy? {
        policies.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
