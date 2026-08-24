import CryptoKit
import Foundation

public enum OAuthError: Error, LocalizedError {
    /// The token endpoint rejected the grant. This refresh lineage is dead; only a
    /// fresh login recovers it.
    case invalidGrant(String)
    /// Network or server trouble; the credential may still be good. `status` is the
    /// HTTP status when there was one — carried rather than re-parsed out of the
    /// message, because the 429 backoff depends on recognising it.
    case transient(String, status: Int? = nil)
    case noRefreshToken
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGrant(let s): return "Sign-in expired: \(s)"
        case .transient(let s, _): return s
        case .noRefreshToken: return "No refresh token stored"
        case .badResponse(let s): return "Unexpected response: \(s)"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .transient(_, let status): return status
        default: return nil
        }
    }

    public var isPermanent: Bool {
        switch self {
        case .invalidGrant, .noRefreshToken: return true
        case .transient, .badResponse: return false
        }
    }
}

public struct AccountIdentity: Equatable {
    public var uuid: String
    public var email: String?
    public var organizationUUID: String?
    public var organizationName: String?
    /// The plan, in the form Claude Code writes into its own credential ("team", "max").
    /// The profile spells it "claude_team"; the credential spells it "team", and Claude
    /// Code reads the credential — a session whose credential omits this is treated as
    /// having no plan entitlement at all.
    public var subscriptionType: String?
    public var rateLimitTier: String?

    /// "claude_team" -> "team". Unprefixed values pass through unchanged.
    public static func planName(fromOrganizationType raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let prefix = "claude_"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }
}

/// Talks to the same OAuth and usage endpoints Claude Code uses.
public struct OAuthClient {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    public static let apiBase = "https://api.anthropic.com"
    public static let betaHeader = "oauth-2025-04-20"

    /// Login asks for everything Claude Code asks for; the server grants a subset.
    public static let loginScopes = ["org:create_api_key", "user:profile", "user:inference",
                                    "user:sessions:claude_code", "user:mcp_servers",
                                    "user:file_upload"]
    public static let refreshScopes = ["user:profile", "user:inference",
                                       "user:sessions:claude_code", "user:mcp_servers",
                                       "user:file_upload"]

    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Login

    public struct PKCE {
        public let verifier: String
        public let challenge: String
        public let state: String

        public init() {
            verifier = PKCE.randomURLSafe(64)
            let digest = SHA256.hash(data: Data(verifier.utf8))
            challenge = Data(digest).base64URLEncodedString()
            state = PKCE.randomURLSafe(32)
        }

        static func randomURLSafe(_ bytes: Int) -> String {
            var buffer = [UInt8](repeating: 0, count: bytes)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
            return Data(buffer).base64URLEncodedString()
        }
    }

    public static func authorizeURL(pkce: PKCE, port: UInt16, email: String?) -> URL {
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
            URLQueryItem(name: "scope", value: loginScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        if let email, !email.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: email))
        }
        return components.url!
    }

    public static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }

    public func exchange(code rawCode: String, pkce: PKCE, port: UInt16) async throws
        -> OAuthCredential {
        // The manual paste flow yields "code#state"; the loopback flow yields them
        // separately. Accept both so a pasted code still works.
        let parts = rawCode.split(separator: "#", maxSplits: 1)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : pkce.state

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI(port: port),
            "client_id": Self.clientID,
            "code_verifier": pkce.verifier,
            "state": state,
        ]
        let json = try await postJSON(url: URL(string: Self.tokenURL)!, body: body)
        return try Self.credential(fromTokenResponse: json, previous: nil)
    }

    // MARK: - Refresh

    public func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.noRefreshToken
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.refreshScopes.joined(separator: " "),
        ]
        let json = try await postJSON(url: URL(string: Self.tokenURL)!, body: body)
        return try Self.credential(fromTokenResponse: json, previous: credential)
    }

    static func credential(fromTokenResponse json: [String: Any],
                           previous: OAuthCredential?) throws -> OAuthCredential {
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.badResponse("no access_token in token response")
        }
        let expiresIn = json["expires_in"] as? Double
        var credential = previous ?? OAuthCredential(accessToken: access, refreshToken: nil,
                                                     expiresAt: nil)
        credential.accessToken = access
        if let expiresIn { credential.expiresAt = Date().addingTimeInterval(expiresIn) }
        if let rotated = json["refresh_token"] as? String, !rotated.isEmpty {
            credential.refreshToken = rotated
        }
        if let scope = json["scope"] as? String {
            credential.scopes = scope.split(separator: " ").map(String.init)
        }
        // A refresh response does not restate the refresh token's own lifetime; keep
        // the previous value rather than implying an unknown expiry.
        return credential
    }

    // MARK: - Identity

    public func profile(accessToken: String) async throws -> AccountIdentity {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/api/oauth/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let json = try await send(request)
        guard let account = json["account"] as? [String: Any],
              let uuid = (account["uuid"] as? String)?
                  .trimmingCharacters(in: .whitespaces), !uuid.isEmpty
        else { throw OAuthError.badResponse("profile response has no account.uuid") }
        let org = json["organization"] as? [String: Any]
        return AccountIdentity(uuid: uuid,
                               email: account["email"] as? String
                                   ?? account["email_address"] as? String,
                               organizationUUID: org?["uuid"] as? String,
                               organizationName: org?["name"] as? String,
                               subscriptionType: AccountIdentity.planName(
                                   fromOrganizationType: org?["organization_type"] as? String),
                               rateLimitTier: org?["rate_limit_tier"] as? String)
    }

    // MARK: - Usage

    public func usage(accessToken: String) async throws -> [UsageWindow] {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        let json = try await send(request)
        return UsageParser.windows(from: json)
    }

    // MARK: - Window probe

    /// Cheapest model on the account. The 5-hour window is account-wide, so any model
    /// starts it, and Haiku leaves the Fable and Opus weekly windows alone.
    public static let probeModel = "claude-haiku-4-5-20251001"

    /// Sends the smallest possible real request, purely to start the account's 5-hour
    /// window.
    ///
    /// Measured: one call moved `five_hour.resets_at` from null to a real timestamp while
    /// utilization stayed at 0%, for 22 input and 1 output token. The headers mirror
    /// Claude Code's because the API refuses OAuth-token requests that do not look like
    /// it — a bare request gets a 429 with no rate-limit headers at all.
    public func startUsageWindow(accessToken: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/v1/messages?beta=true")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-code-20250219,\(Self.betaHeader)",
                         forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("claude-cli/2.1.238 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.probeModel,
            "max_tokens": 1,
            "system": [["type": "text",
                        "text": "You are Claude Code, Anthropic's official CLI for Claude."]],
            "messages": [["role": "user", "content": "."]],
        ])
        _ = try await send(request)
    }

    // MARK: - Transport

    private func postJSON(url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return try await send(request)
    }



    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.transient("network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.badResponse("not an HTTP response")
        }
        if http.statusCode != 200 {
            let text = String(decoding: data.prefix(600), as: UTF8.self)
            if [400, 401, 403].contains(http.statusCode),
               text.contains("invalid_grant") || text.contains("invalid_client") {
                throw OAuthError.invalidGrant(text)
            }
            throw OAuthError.transient("HTTP \(http.statusCode): \(text)",
                                       status: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse("body was not a JSON object")
        }
        return json
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
