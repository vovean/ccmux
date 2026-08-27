import Foundation

/// The payload Claude Code stores under `claudeAiOauth`. Round-trips unknown keys so
/// seeding a namespace never drops a field a newer Claude Code added.
public struct OAuthCredential: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?
    private var extra: [String: JSONValue]

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?,
                refreshTokenExpiresAt: Date? = nil, scopes: [String] = [],
                subscriptionType: String? = nil, rateLimitTier: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.extra = extra
    }

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { return nil }

        accessToken = access
        refreshToken = oauth["refreshToken"] as? String
        expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        refreshTokenExpiresAt = (oauth["refreshTokenExpiresAt"] as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        scopes = oauth["scopes"] as? [String] ?? []
        subscriptionType = oauth["subscriptionType"] as? String
        rateLimitTier = oauth["rateLimitTier"] as? String

        for key in ["accessToken", "refreshToken", "expiresAt", "refreshTokenExpiresAt",
                    "scopes", "subscriptionType", "rateLimitTier"] {
            oauth.removeValue(forKey: key)
        }
        extra = oauth.compactMapValues { JSONValue(any: $0) }
    }

    public func jsonString() -> String {
        var oauth: [String: Any] = [:]
        for (key, value) in extra { oauth[key] = value.anyValue }
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000) }
        if let refreshTokenExpiresAt {
            oauth["refreshTokenExpiresAt"] = Int(refreshTokenExpiresAt.timeIntervalSince1970 * 1000)
        }
        if !scopes.isEmpty { oauth["scopes"] = scopes }
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }

        let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth],
                                               options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Claude Code's own buffer: a token inside it is treated as already expired.
    public static let expiryBuffer: TimeInterval = 5 * 60

    public var isAccessTokenExpired: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(Self.expiryBuffer) >= expiresAt
    }

}

/// Minimal JSON value so unknown credential keys survive a round-trip.
public enum JSONValue: Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init?(any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as NSNumber:
            // NSNumber bridges Bool too; the Bool case above already caught those.
            self = .number(v.doubleValue)
        case is NSNull: self = .null
        case let v as [Any]: self = .array(v.compactMap { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.compactMapValues { JSONValue(any: $0) })
        default: return nil
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}

public extension OAuthCredential {
    /// A stand-in written into the namespace of a session running on an API key.
    ///
    /// It authenticates nothing: the proxy swaps the header for `x-api-key` on every
    /// request. It exists only because Claude Code checks for a credential at startup and
    /// refuses to run without one. The token is deliberately not a real-looking secret,
    /// and there is no refresh token, so nothing here can rotate a lineage.
    static func placeholderForAPIKeySession(now: Date = Date()) -> OAuthCredential {
        OAuthCredential(accessToken: "ccmux-api-key-session",
                        refreshToken: nil,
                        expiresAt: now.addingTimeInterval(365 * 86_400),
                        scopes: ["user:inference", "user:profile"])
    }
}
