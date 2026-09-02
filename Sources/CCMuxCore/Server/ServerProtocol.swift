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
    ///
    /// Adding a route or an optional field does not qualify. The check is an equality
    /// test, so a bump strands every Mac that has not upgraded yet — new capability is
    /// advertised through `HealthResponse.features` instead.
    public static let version = 1

    /// Cross-machine session visibility. Absent from a ccmuxd built before it existed,
    /// whose new routes answer 404.
    public static let sessionsFeature = "sessions"
    public static let hooksFeature = "hooks"
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
    /// Optional because a server built before features existed omits the key entirely,
    /// and a non-optional array would fail the whole decode — turning an old-but-working
    /// server into an unreachable one.
    public var features: [String]?
    public var machines: Int?

    public init(apiVersion: Int = ServerAPI.version, accounts: Int,
                uptimeSeconds: TimeInterval, features: [String]? = nil,
                machines: Int? = nil) {
        self.apiVersion = apiVersion
        self.accounts = accounts
        self.uptimeSeconds = uptimeSeconds
        self.features = features
        self.machines = machines
    }

    public func supports(_ feature: String) -> Bool {
        features?.contains(feature) ?? false
    }
}

// MARK: - Sessions across machines

/// One session as the Mac running it describes it.
///
/// No pid and no port: they are meaningless on another host, and leaving them out is what
/// keeps a foreign card from ever growing a control that would act on the wrong process.
///
/// Every time here is an age in seconds rather than a timestamp. Three clocks are involved
/// — two laptops and a VPS — so the reader adds the reporting machine's own staleness to
/// these, and no absolute time ever crosses a machine boundary.
public struct MachineSession: Codable, Equatable, Sendable {
    public var id: String
    public var accountID: String
    /// SHA-256 of the API key when the account is one. Such an account's `id` is generated
    /// by whichever Mac added it, so this is the only thing that matches one across two.
    public var accountFingerprint: String?
    /// Carried so a session for an account this Mac has never seen still has a name to be
    /// grouped under, rather than eight characters of UUID.
    public var accountLabel: String
    public var name: String
    public var directory: String?
    public var policy: String
    /// "busy", "waiting", "idle", or empty when Claude Code has not said.
    public var status: String
    public var startedSecondsAgo: TimeInterval
    public var updatedSecondsAgo: TimeInterval?
    public var spendUSD: Double

    public init(id: String, accountID: String, accountFingerprint: String? = nil,
                accountLabel: String, name: String, directory: String? = nil,
                policy: String, status: String, startedSecondsAgo: TimeInterval,
                updatedSecondsAgo: TimeInterval? = nil, spendUSD: Double = 0) {
        self.id = id
        self.accountID = accountID
        self.accountFingerprint = accountFingerprint
        self.accountLabel = accountLabel
        self.name = name
        self.directory = directory
        self.policy = policy
        self.status = status
        self.startedSecondsAgo = startedSecondsAgo
        self.updatedSecondsAgo = updatedSecondsAgo
        self.spendUSD = spendUSD
    }
}

/// One Mac's entire session list. A whole snapshot, never a delta: a session that ended is
/// simply absent from the next one, which makes a clean exit, a `kill -9` and a closed lid
/// indistinguishable to the server.
public struct MachineReport: Codable, Equatable, Sendable {
    public var label: String
    public var sessions: [MachineSession]

    public init(label: String, sessions: [MachineSession]) {
        self.label = label
        self.sessions = sessions
    }
}

public struct MachineSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var machineID: String
    public var label: String
    public var sessions: [MachineSession]
    /// Since this machine last reported. Added to each session's own age to get a real
    /// one, and on its own it decides whether the machine reads as current, as stale, or
    /// is not shown at all.
    public var ageSeconds: TimeInterval

    public var id: String { machineID }

    public init(machineID: String, label: String, sessions: [MachineSession],
                ageSeconds: TimeInterval) {
        self.machineID = machineID
        self.label = label
        self.sessions = sessions
        self.ageSeconds = ageSeconds
    }
}

public struct SessionsResponse: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var machines: [MachineSnapshot]

    public init(apiVersion: Int = ServerAPI.version, machines: [MachineSnapshot]) {
        self.apiVersion = apiVersion
        self.machines = machines
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

/// One hook script the server holds for every Mac to run.
public struct HookFile: Codable, Equatable, Sendable {
    public var path: String
    public var content: String
    public var executable: Bool

    public init(path: String, content: String, executable: Bool) {
        self.path = path
        self.content = content
        self.executable = executable
    }

    private enum CodingKeys: String, CodingKey { case path, content, executable }

    /// `executable` is absent from a hand-written bundle more often than not, and a hook
    /// that arrives non-executable simply never runs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        content = try c.decode(String.self, forKey: .content)
        executable = try c.decodeIfPresent(Bool.self, forKey: .executable) ?? false
    }
}

/// The whole hook set, identified by a content hash so a Mac can tell in one comparison
/// whether it has anything to write.
public struct HookBundle: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var version: String
    public var updatedAt: Date?
    public var files: [HookFile]

    public init(apiVersion: Int = ServerAPI.version, version: String,
                updatedAt: Date? = nil, files: [HookFile]) {
        self.apiVersion = apiVersion
        self.version = version
        self.updatedAt = updatedAt
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case apiVersion, version, updatedAt, files }

    /// `version` and `files` are required, deliberately against the leniency used
    /// elsewhere in this file. Whatever this decodes to decides which executable files get
    /// deleted, so a truncated or half-written answer has to fail the decode and land in
    /// the retry path — defaulting it to an empty set would read as an authoritative
    /// instruction to remove every hook on the machine.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? ServerAPI.version
        version = try c.decode(String.self, forKey: .version)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        files = try c.decode([HookFile].self, forKey: .files)
        if version.isEmpty { throw ServerProtocolError.emptyHookVersion }
    }
}

public enum ServerProtocolError: Error, LocalizedError, Equatable {
    case emptyHookVersion
    public var errorDescription: String? {
        switch self {
        case .emptyHookVersion: return "the hook bundle carried no version"
        }
    }
}

public struct HookPushRequest: Codable, Equatable, Sendable {
    public var files: [HookFile]
    public init(files: [HookFile]) { self.files = files }
}

public extension String {
    /// How an API key is identified across machines, where its account id cannot be.
    var apiKeyFingerprint: String {
        CryptoShim.sha256Hex(Data(utf8))
    }
}
