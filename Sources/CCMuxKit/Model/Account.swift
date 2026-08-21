import Foundation

public enum AccountHealth: String, Codable, Equatable {
    case ok
    case needsRelogin
    case unknown
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

    public init(id: String, label: String, email: String? = nil,
                organizationUUID: String? = nil, organizationName: String? = nil,
                subscriptionType: String? = nil, rateLimitTier: String? = nil,
                priority: Int = 0, chromeProfileDirectory: String? = nil,
                health: AccountHealth = .unknown,
                healthDetail: String? = nil, addedAt: Date = Date()) {
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
    }

    public var displayName: String {
        label.isEmpty ? (email ?? id) : label
    }
}
