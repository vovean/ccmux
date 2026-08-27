import Foundation

/// What can be carried to another Mac, and deliberately what cannot.
///
/// No OAuth credential is ever written here. Multiple sign-in lineages for one account
/// coexist happily — that is measured, not assumed — but two machines holding *the same*
/// lineage do not: whichever refreshes first invalidates the other, and that account dies
/// there with nothing to show why. So a subscription is re-signed-in on the target
/// machine. An API key is the opposite case: a static secret, safe on as many machines as
/// you like, so it travels whole when the export asks for secrets.
public struct AccountBundle: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var accounts: [Entry]
    /// Absent unless the export included them; nil leaves the target's own settings alone.
    public var policies: [Policy]?
    public var thresholds: Thresholds?

    public struct Entry: Codable, Equatable {
        /// The Anthropic account UUID, which is the same on every machine — verified
        /// against a local account and the `oauthAccount.accountUuid` Claude Code writes.
        /// That makes matching exact rather than a guess at the label.
        public var id: String
        public var label: String
        public var email: String?
        public var organizationUUID: String?
        public var organizationName: String?
        public var subscriptionType: String?
        public var rateLimitTier: String?
        public var priority: Int
        public var inRotation: Bool
        public var kind: AccountKind
        public var monthlyBudgetUSD: Double?
        /// The Google account this subscription signs in with, and the name to give the
        /// Chrome profile that holds it. The profile *directory* is deliberately not
        /// carried: "Profile 3" names a different account on every machine.
        public var chromeProfileName: String?
        public var chromeProfileEmail: String?
        /// Only when exported with secrets, and only ever for an API key.
        public var apiKey: String?

        public init(id: String, label: String, email: String? = nil,
                    organizationUUID: String? = nil, organizationName: String? = nil,
                    subscriptionType: String? = nil, rateLimitTier: String? = nil,
                    priority: Int = 0, inRotation: Bool = true,
                    kind: AccountKind = .subscription, monthlyBudgetUSD: Double? = nil,
                    chromeProfileName: String? = nil, chromeProfileEmail: String? = nil,
                    apiKey: String? = nil) {
            self.id = id
            self.label = label
            self.email = email
            self.organizationUUID = organizationUUID
            self.organizationName = organizationName
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
            self.priority = priority
            self.inRotation = inRotation
            self.kind = kind
            self.monthlyBudgetUSD = monthlyBudgetUSD
            self.chromeProfileName = chromeProfileName
            self.chromeProfileEmail = chromeProfileEmail
            self.apiKey = apiKey
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            email = try c.decodeIfPresent(String.self, forKey: .email)
            organizationUUID = try c.decodeIfPresent(String.self, forKey: .organizationUUID)
            organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
            subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
            rateLimitTier = try c.decodeIfPresent(String.self, forKey: .rateLimitTier)
            priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
            inRotation = try c.decodeIfPresent(Bool.self, forKey: .inRotation) ?? true
            kind = try c.decodeIfPresent(AccountKind.self, forKey: .kind) ?? .subscription
            monthlyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)
            chromeProfileName = try c.decodeIfPresent(String.self, forKey: .chromeProfileName)
            chromeProfileEmail = try c.decodeIfPresent(String.self,
                                                       forKey: .chromeProfileEmail)
            apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        }

        public var displayName: String { label.isEmpty ? (email ?? id) : label }
    }

    /// The knobs, without anything machine-specific. Directory bindings and the outbound
    /// proxy are not here on purpose: bindings name absolute paths that mean nothing on
    /// another machine, and the proxy is per-network.
    public struct Thresholds: Codable, Equatable {
        public var warnThresholdPercent: Double
        public var budgetWarnPercent: Double
        public var watchedWindows: [UsageWindow.Kind]
        public var autoSwitch: AutoSwitchMode
        public var notifyOnAutoSwitch: Bool
        public var notifyOnReloginNeeded: Bool
        public var keepWindowsRolling: Bool

        public init(_ settings: Settings) {
            warnThresholdPercent = settings.warnThresholdPercent
            budgetWarnPercent = settings.budgetWarnPercent
            watchedWindows = settings.watchedWindows
            autoSwitch = settings.autoSwitch
            notifyOnAutoSwitch = settings.notifyOnAutoSwitch
            notifyOnReloginNeeded = settings.notifyOnReloginNeeded
            keepWindowsRolling = settings.keepWindowsRolling
        }

        public func apply(to settings: inout Settings) {
            settings.warnThresholdPercent = warnThresholdPercent
            settings.budgetWarnPercent = budgetWarnPercent
            settings.watchedWindows = watchedWindows
            settings.autoSwitch = autoSwitch
            settings.notifyOnAutoSwitch = notifyOnAutoSwitch
            settings.notifyOnReloginNeeded = notifyOnReloginNeeded
            settings.keepWindowsRolling = keepWindowsRolling
        }
    }

    public init(version: Int = AccountBundle.currentVersion, exportedAt: Date = Date(),
                accounts: [Entry], policies: [Policy]? = nil,
                thresholds: Thresholds? = nil) {
        self.version = version
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.policies = policies
        self.thresholds = thresholds
    }

    public var carriesSecrets: Bool { accounts.contains { $0.apiKey?.isEmpty == false } }

    /// The coder lives here rather than at each call site. The date strategy has to match
    /// on both ends, and a caller that configured it differently would write a file that
    /// nothing can read back — with the mismatch only showing up on the other machine.
    public static func coders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    public func encoded() throws -> Data { try Self.coders().0.encode(self) }

    public static func decoded(from data: Data) throws -> AccountBundle {
        try coders().1.decode(AccountBundle.self, from: data)
    }
}
