import Foundation

/// The ccmuxd wire types, shared by both sides so they cannot drift.
///
/// The shape of this API is decided by one rule: a refresh token never appears in a
/// response. The server is the sole holder of every lineage, so it hands out access
/// tokens — which expire on their own — and nothing that could rotate a lineage behind
/// its back. `adopt` is the single exception and goes the other way, client to server.
public enum ServerAPI {
    public static let prefix = "/v1"
    /// Bumped when a change would make an older client misread a response. The client
    /// checks it on connect and says so plainly rather than failing in pieces later.
    public static let version = 1
}

/// An account as the server describes it. Deliberately not `Account`: the client's record
/// carries local concerns (priority, Chrome profile, rotation, spend) that are per-machine
/// and have no business being centralised.
public struct RemoteAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var email: String?
    public var organizationUUID: String?
    public var organizationName: String?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var kind: AccountKind
    public var health: AccountHealth
    public var healthDetail: String?
    /// SHA-256 of the API key. An API-key account's `id` is a locally generated UUID and
    /// so differs on every machine; this is the only thing that can match one across two.
    public var apiKeyFingerprint: String?

    public init(id: String, label: String, email: String? = nil,
                organizationUUID: String? = nil, organizationName: String? = nil,
                subscriptionType: String? = nil, rateLimitTier: String? = nil,
                kind: AccountKind = .subscription, health: AccountHealth = .unknown,
                healthDetail: String? = nil, apiKeyFingerprint: String? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.kind = kind
        self.health = health
        self.healthDetail = healthDetail
        self.apiKeyFingerprint = apiKeyFingerprint
    }

    public var displayName: String { label.isEmpty ? (email ?? id) : label }
}

/// One access token, plus what Claude Code needs stamped into a seeded namespace.
///
/// `expiresIn` is seconds, not an absolute date, on purpose: the server and a laptop do
/// not agree on the wall clock, and a client that trusted a remote timestamp would treat
/// tokens as fresh that the API considers dead.
public struct TokenGrant: Codable, Equatable, Sendable {
    public var accountID: String
    public var kind: AccountKind
    public var accessToken: String?
    public var apiKey: String?
    public var expiresIn: TimeInterval?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var scopes: [String]

    public init(accountID: String, kind: AccountKind, accessToken: String? = nil,
                apiKey: String? = nil, expiresIn: TimeInterval? = nil,
                subscriptionType: String? = nil, rateLimitTier: String? = nil,
                scopes: [String] = []) {
        self.accountID = accountID
        self.kind = kind
        self.accessToken = accessToken
        self.apiKey = apiKey
        self.expiresIn = expiresIn
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.scopes = scopes
    }

    /// Whether this grant can actually serve a request.
    ///
    /// A non-nil access token is not enough. The server returns what it holds even when a
    /// refresh failed, so a grant can carry a token that expired minutes ago — and a
    /// client that overwrote its own working credential with one of those would destroy
    /// the only refresh token it had.
    public var isUsable: Bool {
        switch kind {
        case .apiKey:
            return !(apiKey ?? "").isEmpty
        case .subscription:
            guard let accessToken, !accessToken.isEmpty else { return false }
            // A server that did not say leaves it to expiry handling, not to this.
            guard let expiresIn else { return true }
            return expiresIn > 0
        }
    }

    /// Rebuilt as the credential shape the rest of ccmux already speaks. No refresh token
    /// by construction — the server did not send one, and `neuteredForSession` would strip
    /// it anyway.
    public func credential(now: Date = Date()) -> OAuthCredential? {
        guard let accessToken else { return nil }
        return OAuthCredential(accessToken: accessToken,
                               refreshToken: nil,
                               expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                               scopes: scopes,
                               subscriptionType: subscriptionType,
                               rateLimitTier: rateLimitTier)
    }
}

public struct RemoteUsage: Codable, Equatable, Sendable {
    public var accountID: String
    public var windows: [UsageWindow]
    /// How stale the server's snapshot is, in seconds. Same reasoning as `expiresIn`.
    public var ageSeconds: TimeInterval

    public init(accountID: String, windows: [UsageWindow], ageSeconds: TimeInterval) {
        self.accountID = accountID
        self.windows = windows
        self.ageSeconds = ageSeconds
    }
}

// MARK: - Login relay

/// The client asks the server to begin a login. The server keeps the PKCE verifier, so
/// the code the browser hands back is worthless to anyone who intercepts it, and the
/// refresh token that comes out of the exchange is born on the server.
public struct LoginStartRequest: Codable, Equatable, Sendable {
    /// The port the client's own loopback listener is on. The redirect stays on
    /// localhost — the browser runs on the client, so the code lands there.
    public var redirectPort: UInt16
    public var accountID: String?
    public var loginHint: String?

    public init(redirectPort: UInt16, accountID: String? = nil, loginHint: String? = nil) {
        self.redirectPort = redirectPort
        self.accountID = accountID
        self.loginHint = loginHint
    }
}

public struct LoginStartResponse: Codable, Equatable, Sendable {
    public var loginID: String
    public var authorizeURL: String
    /// Echoed so the client can check the browser's `state` before relaying the code,
    /// exactly as it does for a local login.
    public var state: String

    public init(loginID: String, authorizeURL: String, state: String) {
        self.loginID = loginID
        self.authorizeURL = authorizeURL
        self.state = state
    }
}

public struct LoginFinishRequest: Codable, Equatable, Sendable {
    public var loginID: String
    public var code: String
    public var state: String?

    public init(loginID: String, code: String, state: String? = nil) {
        self.loginID = loginID
        self.code = code
        self.state = state
    }
}

// MARK: - Adopt

/// A client handing a credential it already holds up to the server. The one direction in
/// which a refresh token crosses the wire, which is why it is never automatic.
public struct AdoptRequest: Codable, Equatable, Sendable {
    /// `OAuthCredential.jsonString()` for a subscription.
    public var credentialJSON: String?
    /// The raw key for an API-key account.
    public var apiKey: String?
    public var label: String?

    public init(credentialJSON: String? = nil, apiKey: String? = nil, label: String? = nil) {
        self.credentialJSON = credentialJSON
        self.apiKey = apiKey
        self.label = label
    }
}

// MARK: - Envelopes

public struct AccountListResponse: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var accounts: [RemoteAccount]

    public init(apiVersion: Int = ServerAPI.version, accounts: [RemoteAccount]) {
        self.apiVersion = apiVersion
        self.accounts = accounts
    }
}

public struct HealthResponse: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var accounts: Int
    public var uptimeSeconds: TimeInterval

    public init(apiVersion: Int = ServerAPI.version, accounts: Int,
                uptimeSeconds: TimeInterval) {
        self.apiVersion = apiVersion
        self.accounts = accounts
        self.uptimeSeconds = uptimeSeconds
    }
}

/// The shape Hummingbird actually emits for an `HTTPError`: `{"error":{"message":"…"}}`.
/// Measured against a running ccmuxd — a flat `{"error":"…"}` decodes to nothing and the
/// client would show the raw JSON instead of the message.
public struct ServerErrorResponse: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public var message: String?
        public init(message: String?) { self.message = message }
    }
    public var error: Detail

    public init(message: String) { self.error = Detail(message: message) }

    public var message: String? { error.message }
}

public extension String {
    /// How an API key is identified across machines, where its account id cannot be.
    var apiKeyFingerprint: String {
        CryptoShim.sha256Hex(Data(utf8))
    }
}
