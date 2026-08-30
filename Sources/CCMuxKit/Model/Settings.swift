import CCMuxCore
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

    /// Hand-written rather than synthesized: synthesized decoding requires every key,
    /// so a settings file written before a field existed fails to decode entirely and
    /// `Store` silently falls back to defaults — turning, say, `autoSwitch: off` into
    /// `immediate` on upgrade. Verified: an inline default on the property does *not*
    /// make the synthesized decoder tolerant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Policy(name: "", requiredWindows: [])
        name = try c.decode(String.self, forKey: .name)
        requiredWindows = try c.decodeIfPresent([UsageWindow.Kind].self,
                                                forKey: .requiredWindows) ?? []
        scopedModel = try c.decodeIfPresent(String.self, forKey: .scopedModel)
        launchFloors = try c.decodeIfPresent([String: Double].self, forKey: .launchFloors)
            ?? fallback.launchFloors
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

/// A ccmuxd this Mac has been told to trust. The password is not here — it lives in the
/// Keychain, because settings.json is plaintext on disk.
public struct ServerConnection: Codable, Equatable, Sendable {
    public var url: String
    public var username: String
    /// SHA-256 of the server's TLS certificate, agreed once on first connect. Checked on
    /// every request: a self-signed certificate has no CA behind it, so this pin is the
    /// only thing distinguishing the real server from anything else on that address.
    public var fingerprint: String

    public init(url: String, username: String, fingerprint: String) {
        self.url = url
        self.username = username
        self.fingerprint = fingerprint
    }
}

public struct Settings: Codable, Equatable {
    public var warnThresholdPercent: Double
    /// Percentage of an API-key account's monthly budget at which to warn.
    public var budgetWarnPercent: Double
    /// Sends every outbound ccmux request through this proxy. Process-local: it does not
    /// touch system proxy settings or routing, and affects nothing but ccmux.
    public var upstreamProxy: UpstreamProxy?
    public var watchedWindows: [UsageWindow.Kind]
    public var autoSwitch: AutoSwitchMode
    public var policies: [Policy]
    public var notifyOnAutoSwitch: Bool
    public var notifyOnReloginNeeded: Bool
    public var mutedAccountIDs: [String]
    /// Start each account's 5-hour window as soon as it is idle, so the cycle keeps
    /// rolling while you are away and less of it is left to wait out when you return.
    public var keepWindowsRolling: Bool
    /// Directories whose sessions must launch on a particular account. Launch only —
    /// see `DirectoryBinding`.
    public var directoryBindings: [DirectoryBinding]
    public var server: ServerConnection?
    /// Whether sessions running on other Macs are shown here. Display only — this Mac
    /// keeps reporting its own either way, so turning it off on a laptop does not blank
    /// that laptop's sessions everywhere else.
    public var showForeignSessions: Bool
    /// Accounts whose refresh lineage now belongs to the server. This Mac holds only
    /// short-lived access tokens for them and must never run a refresh grant of its own —
    /// that is precisely the two-holders-of-one-lineage case that logs an account out.
    public var delegatedAccountIDs: [String]

    public init(warnThresholdPercent: Double = 3,
                budgetWarnPercent: Double = 80,
                upstreamProxy: UpstreamProxy? = nil,
                watchedWindows: [UsageWindow.Kind] = [.session, .weeklyAll, .weeklyScoped],
                autoSwitch: AutoSwitchMode = .immediate,
                policies: [Policy] = Policy.defaults,
                notifyOnAutoSwitch: Bool = true,
                notifyOnReloginNeeded: Bool = true,
                mutedAccountIDs: [String] = [],
                keepWindowsRolling: Bool = true,
                directoryBindings: [DirectoryBinding] = [],
                server: ServerConnection? = nil,
                showForeignSessions: Bool = true,
                delegatedAccountIDs: [String] = []) {
        self.warnThresholdPercent = warnThresholdPercent
        self.budgetWarnPercent = budgetWarnPercent
        self.upstreamProxy = upstreamProxy
        self.watchedWindows = watchedWindows
        self.autoSwitch = autoSwitch
        self.policies = policies
        self.notifyOnAutoSwitch = notifyOnAutoSwitch
        self.notifyOnReloginNeeded = notifyOnReloginNeeded
        self.mutedAccountIDs = mutedAccountIDs
        self.keepWindowsRolling = keepWindowsRolling
        self.directoryBindings = directoryBindings
        self.server = server
        self.showForeignSessions = showForeignSessions
        self.delegatedAccountIDs = delegatedAccountIDs
    }

    /// See `Policy.init(from:)`: tolerant of keys an older build did not write, so an
    /// upgrade never silently discards the settings the user chose. Verified that an
    /// inline default on the property does *not* make the synthesized decoder tolerant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        warnThresholdPercent = try c.decodeIfPresent(Double.self,
                                                     forKey: .warnThresholdPercent)
            ?? d.warnThresholdPercent
        budgetWarnPercent = try c.decodeIfPresent(Double.self,
                                                  forKey: .budgetWarnPercent)
            ?? d.budgetWarnPercent
        upstreamProxy = try c.decodeIfPresent(UpstreamProxy.self, forKey: .upstreamProxy)
        watchedWindows = try c.decodeIfPresent([UsageWindow.Kind].self,
                                               forKey: .watchedWindows) ?? d.watchedWindows
        autoSwitch = try c.decodeIfPresent(AutoSwitchMode.self, forKey: .autoSwitch)
            ?? d.autoSwitch
        policies = try c.decodeIfPresent([Policy].self, forKey: .policies) ?? d.policies
        notifyOnAutoSwitch = try c.decodeIfPresent(Bool.self, forKey: .notifyOnAutoSwitch)
            ?? d.notifyOnAutoSwitch
        notifyOnReloginNeeded = try c.decodeIfPresent(Bool.self,
                                                      forKey: .notifyOnReloginNeeded)
            ?? d.notifyOnReloginNeeded
        mutedAccountIDs = try c.decodeIfPresent([String].self, forKey: .mutedAccountIDs)
            ?? d.mutedAccountIDs
        keepWindowsRolling = try c.decodeIfPresent(Bool.self, forKey: .keepWindowsRolling)
            ?? d.keepWindowsRolling
        directoryBindings = try c.decodeIfPresent([DirectoryBinding].self,
                                                  forKey: .directoryBindings)
            ?? d.directoryBindings
        server = try c.decodeIfPresent(ServerConnection.self, forKey: .server)
        showForeignSessions = try c.decodeIfPresent(Bool.self, forKey: .showForeignSessions)
            ?? d.showForeignSessions
        delegatedAccountIDs = try c.decodeIfPresent([String].self,
                                                    forKey: .delegatedAccountIDs)
            ?? d.delegatedAccountIDs
    }

    public var delegated: Set<String> { Set(delegatedAccountIDs) }

    /// Replaces any rule for the same directory rather than letting two rules for one
    /// path both sit in the file, where which one wins would come down to array order.
    public mutating func bind(_ path: String, to accountID: String) {
        let key = DirectoryBindings.components(path)
        directoryBindings.removeAll { DirectoryBindings.components($0.path) == key }
        directoryBindings.append(DirectoryBinding(path: path, accountID: accountID))
        directoryBindings.sort { $0.path < $1.path }
    }

    public mutating func unbind(_ path: String) {
        let key = DirectoryBindings.components(path)
        directoryBindings.removeAll { DirectoryBindings.components($0.path) == key }
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
