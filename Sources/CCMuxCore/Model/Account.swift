import Foundation

public enum AccountHealth: String, Codable, Equatable, Sendable {
    case ok
    case needsRelogin
    case unknown
}

/// What ccmux authenticates as. Subscriptions have quota and no per-request cost;
/// an API key has the inverse, so almost every policy decision branches on this.
public enum AccountKind: String, Codable, Equatable, Sendable {
    case subscription
    case apiKey
}

/// Spend in one calendar month, so a monthly budget resets without a scheduled job.
public struct MonthlySpend: Codable, Equatable {
    /// "2026-08". Comparing this to the current month is the whole reset mechanism.
    public var month: String
    public var amountUSD: Double

    public init(month: String, amountUSD: Double) {
        self.month = month
        self.amountUSD = amountUSD
    }

    public static func monthKey(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Amount for `date`'s month, treating a stale month as zero rather than carrying it.
    public func amount(inMonthOf date: Date = Date()) -> Double {
        month == Self.monthKey(date) ? amountUSD : 0
    }

    public mutating func add(_ delta: Double, on date: Date = Date()) {
        let key = Self.monthKey(date)
        if month != key { month = key; amountUSD = 0 }
        amountUSD += delta
    }
}

public struct Account: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var email: String?
    public var organizationUUID: String?
    public var organizationName: String?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var priority: Int
    /// Chrome profile directory ("Default", "Profile 2", …) whose signed-in Google
    /// account owns this subscription, so a re-login opens in the right browser
    /// profile instead of whichever one happens to be frontmost.
    public var chromeProfileDirectory: String?
    public var health: AccountHealth
    public var healthDetail: String?
    public var addedAt: Date
    public var kind: AccountKind
    /// Out of rotation means no automatic assignment — not at launch, not on failover.
    /// Assigning by hand still works: the switch governs what ccmux chooses, not what
    /// the user may choose.
    public var inRotation: Bool
    /// Everything ever spent on this account, live sessions and ended ones alike, so
    /// ending a session does not make money appear to vanish.
    public var spendLifetimeUSD: Double
    public var spendThisMonth: MonthlySpend?
    /// Advisory only: crossing it warns, it never blocks a request.
    public var monthlyBudgetUSD: Double?

    public init(id: String, label: String, email: String? = nil,
                organizationUUID: String? = nil, organizationName: String? = nil,
                subscriptionType: String? = nil, rateLimitTier: String? = nil,
                priority: Int = 0, chromeProfileDirectory: String? = nil,
                health: AccountHealth = .unknown,
                healthDetail: String? = nil, addedAt: Date = Date(),
                kind: AccountKind = .subscription, inRotation: Bool = true,
                spendLifetimeUSD: Double = 0, spendThisMonth: MonthlySpend? = nil,
                monthlyBudgetUSD: Double? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.priority = priority
        self.chromeProfileDirectory = chromeProfileDirectory
        self.health = health
        self.healthDetail = healthDetail
        self.addedAt = addedAt
        self.kind = kind
        self.inRotation = inRotation
        self.spendLifetimeUSD = spendLifetimeUSD
        self.spendThisMonth = spendThisMonth
        self.monthlyBudgetUSD = monthlyBudgetUSD
    }

    /// Hand-written so an accounts file written before these fields existed still
    /// decodes. Synthesized decoding requires every key and would reset the whole table.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        organizationUUID = try c.decodeIfPresent(String.self, forKey: .organizationUUID)
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
        subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
        rateLimitTier = try c.decodeIfPresent(String.self, forKey: .rateLimitTier)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        chromeProfileDirectory = try c.decodeIfPresent(String.self,
                                                       forKey: .chromeProfileDirectory)
        health = try c.decodeIfPresent(AccountHealth.self, forKey: .health) ?? .unknown
        healthDetail = try c.decodeIfPresent(String.self, forKey: .healthDetail)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        kind = try c.decodeIfPresent(AccountKind.self, forKey: .kind) ?? .subscription
        inRotation = try c.decodeIfPresent(Bool.self, forKey: .inRotation) ?? true
        spendLifetimeUSD = try c.decodeIfPresent(Double.self,
                                                 forKey: .spendLifetimeUSD) ?? 0
        spendThisMonth = try c.decodeIfPresent(MonthlySpend.self, forKey: .spendThisMonth)
        monthlyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)
    }

    public var displayName: String {
        label.isEmpty ? (email ?? id) : label
    }

    /// Whether this record contradicts the Keychain by claiming not to be an API key.
    ///
    /// A record that lost its `kind` decodes as a subscription in rotation — see the
    /// defaults in `init(from:)` — which makes an API key auto-assignable and therefore
    /// spendable without anyone choosing it, and makes seeding hunt for an OAuth
    /// credential that was never there. A stored key is the evidence that settles it.
    public func contradictsStoredAPIKey(hasStoredAPIKey: Bool) -> Bool {
        hasStoredAPIKey && kind != .apiKey
    }

    /// Whether ccmux may choose this account on its own. An API key is never chosen
    /// automatically: spending money is an explicit decision, so it is reachable only by
    /// assigning a session to it by hand.
    public var isAutoAssignable: Bool {
        inRotation && kind == .subscription
    }
}
