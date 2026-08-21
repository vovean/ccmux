import Foundation

/// A launch policy: what an alias like `cc-fable` requires of an account.
public struct Policy: Codable, Equatable, Identifiable {
    public var name: String
    /// Windows the policy cares about. A window not listed is ignored when ranking,
    /// so `opus` can pick an account whose Fable weekly is exhausted.
    public var requiredWindows: [UsageWindow.Kind]
    /// For `weeklyScoped`, which model's window. nil means every scoped window.
    public var scopedModel: String?
    /// An account is only eligible above this much headroom on every required window.
    public var minHeadroom: Double

    public var id: String { name }

    public init(name: String, requiredWindows: [UsageWindow.Kind],
                scopedModel: String? = nil, minHeadroom: Double = 1) {
        self.name = name
        self.requiredWindows = requiredWindows
        self.scopedModel = scopedModel
        self.minHeadroom = minHeadroom
    }

    public static let defaults: [Policy] = [
        Policy(name: "opus", requiredWindows: [.session, .weeklyAll]),
        Policy(name: "fable", requiredWindows: [.session, .weeklyAll, .weeklyScoped],
               scopedModel: "Fable"),
        Policy(name: "any", requiredWindows: [.session, .weeklyAll]),
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

    public init(warnThresholdPercent: Double = 3,
                watchedWindows: [UsageWindow.Kind] = [.session, .weeklyAll, .weeklyScoped],
                autoSwitch: AutoSwitchMode = .immediate,
                policies: [Policy] = Policy.defaults,
                notifyOnAutoSwitch: Bool = true,
                notifyOnReloginNeeded: Bool = true,
                mutedAccountIDs: [String] = []) {
        self.warnThresholdPercent = warnThresholdPercent
        self.watchedWindows = watchedWindows
        self.autoSwitch = autoSwitch
        self.policies = policies
        self.notifyOnAutoSwitch = notifyOnAutoSwitch
        self.notifyOnReloginNeeded = notifyOnReloginNeeded
        self.mutedAccountIDs = mutedAccountIDs
    }

    public func policy(named name: String) -> Policy? {
        policies.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
