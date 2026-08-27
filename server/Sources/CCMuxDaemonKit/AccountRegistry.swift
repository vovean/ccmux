import CCMuxCore
import Foundation

/// Everything the server owns: the accounts, their refresh lineages, and the usage
/// snapshots clients rank against.
///
/// The whole point of centralising this is the constraint the client has always had to
/// respect — multiple refresh lineages per account are fine, but two holders of one
/// lineage are not, because Anthropic rotates refresh tokens and the loser is told
/// `invalid_grant`. Here there is exactly one holder by construction: a refresh token
/// enters through `adopt` or `finishLogin` and never leaves.
public actor AccountRegistry {
    private let client: OAuthClient
    private let vault: TokenVault
    private let apiKeys: SecretStore
    private let accountsFile: URL
    private let startedAt = Date()

    private var accounts: [String: RemoteAccount] = [:]
    private var usage: [String: UsageSnapshot] = [:]
    private var pendingLogins: [String: PendingLogin] = [:]
    /// When a client last asked for this account's token. The server has no session
    /// knowledge, so this stands in for "in use" when choosing a poll cadence.
    private var lastTokenRequest: [String: Date] = [:]

    /// A login in flight. The verifier lives here and only here, which is what makes the
    /// authorization code useless to anyone who intercepts it on the way back.
    private struct PendingLogin {
        let pkce: OAuthClient.PKCE
        let port: UInt16
        let accountID: String?
        let startedAt: Date
    }

    private static let loginTTL: TimeInterval = 10 * 60
    /// Hand out a token with at least this much life left, so a client that caches it
    /// does not come straight back.
    private static let minimumTokenLife: TimeInterval = 10 * 60
    /// A token whose expiry the server does not know. Short, so the client re-asks.
    private static let unknownTokenLife: TimeInterval = 300
    /// Treated as in use if a client asked for its token this recently.
    private static let inUseWindow: TimeInterval = 600
    /// Matches the client's default `warnThresholdPercent`; the server has no settings of
    /// its own and only needs it to pick a poll cadence.
    private static let pollThreshold: Double = 3

    public init(client: OAuthClient, secrets: SecretStore, accountsFile: URL) {
        self.client = client
        self.accountsFile = accountsFile
        self.apiKeys = PrefixedSecretStore(secrets, prefix: "apikey:")
        self.vault = TokenVault(client: client,
                                secrets: PrefixedSecretStore(secrets, prefix: "oauth:"))
    }

    // MARK: - Lifecycle

    public func bootstrap() {
        let stored = JSONStore.load([RemoteAccount].self, from: accountsFile) ?? []
        for account in stored { accounts[account.id] = account }
        vault.load(accountIDs: stored.filter { $0.kind == .subscription }.map(\.id))

        vault.onRefreshFailure = { [weak self] accountID, error in
            Task { await self?.recordRefreshFailure(accountID, error) }
        }
        vault.onCredentialChanged = { [weak self] accountID, _ in
            Task { await self?.markHealthy(accountID) }
        }
        // A rotation live on Anthropic's side but not on disk means the next restart comes
        // back holding a dead refresh token. Recorded on the account so it reaches every
        // client, not just this process's stdout.
        vault.onPersistFailure = { [weak self] accountID, error in
            Task { await self?.recordPersistFailure(accountID, error) }
        }

        // The sealed store is the authority on what we can actually serve. An account in
        // the file with no credential behind it would otherwise 500 on every token
        // request with nothing saying why.
        let held = Set(vault.storedAccountIDs())
        for account in stored where account.kind == .subscription && !held.contains(account.id) {
            accounts[account.id]?.health = .needsRelogin
            accounts[account.id]?.healthDetail = "no credential on the server"
            Log.warn("account \(account.id) has no stored credential")
        }
        Log.info("loaded \(accounts.count) account(s)")
    }

    public func health() -> HealthResponse {
        HealthResponse(accounts: accounts.count, uptimeSeconds: Date().timeIntervalSince(startedAt))
    }

    public func list() -> [RemoteAccount] {
        accounts.values.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    // MARK: - Tokens

    /// A live access token, refreshing first if what we hold is close to expiry.
    ///
    /// Never returns a refresh token. That is the invariant the whole design rests on, so
    /// it is enforced by what `TokenGrant` can carry rather than by remembering to strip
    /// a field here.
    public func token(for accountID: String) async -> TokenGrant? {
        guard let account = accounts[accountID] else { return nil }
        lastTokenRequest[accountID] = Date()

        if account.kind == .apiKey {
            guard let key = try? apiKeys.read(accountID), !key.isEmpty else { return nil }
            return TokenGrant(accountID: accountID, kind: .apiKey, apiKey: key)
        }

        guard var credential = vault.credential(for: accountID) else { return nil }
        let remaining = credential.expiresAt.map { $0.timeIntervalSinceNow } ?? 0
        if remaining < Self.minimumTokenLife {
            // A failed refresh still yields the old token: the API may honour it inside
            // its own grace period, and a nil here parks a live session for certain.
            credential = await vault.refresh(accountID) ?? credential
        }
        // A token still inside its lifetime is worth returning even when the refresh
        // failed — the API may honour it, and nil parks a live session for certain. One
        // that is already expired is not: the client would overwrite its own working
        // credential with it, so this refuses exactly as a missing credential does.
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSinceNow <= 0 {
            Log.warn("\(accountID) has no live access token and could not be refreshed")
            return nil
        }
        let life = credential.expiresAt.map { max(0, $0.timeIntervalSinceNow) }
            ?? Self.unknownTokenLife
        return TokenGrant(accountID: accountID,
                          kind: .subscription,
                          accessToken: credential.accessToken,
                          expiresIn: life,
                          subscriptionType: credential.subscriptionType
                              ?? account.subscriptionType,
                          rateLimitTier: credential.rateLimitTier ?? account.rateLimitTier,
                          scopes: credential.scopes)
    }

    public func usageSnapshot(for accountID: String) -> RemoteUsage? {
        guard accounts[accountID] != nil, let snapshot = usage[accountID] else { return nil }
        return RemoteUsage(accountID: accountID,
                           windows: snapshot.windows,
                           ageSeconds: max(0, -snapshot.fetchedAt.timeIntervalSinceNow))
    }

    // MARK: - Login relay

    /// Starts a login. The PKCE pair is generated here so the verifier never leaves the
    /// server, which is what keeps the code the browser returns from being redeemable by
    /// anyone else.
    public func startLogin(_ request: LoginStartRequest) -> LoginStartResponse {
        pruneExpiredLogins()
        let pkce = OAuthClient.PKCE()
        let loginID = UUID().uuidString
        pendingLogins[loginID] = PendingLogin(pkce: pkce, port: request.redirectPort,
                                              accountID: request.accountID,
                                              startedAt: Date())
        let hint = request.loginHint ?? request.accountID.flatMap { accounts[$0]?.email }
        let url = OAuthClient.authorizeURL(pkce: pkce, port: request.redirectPort, email: hint)
        return LoginStartResponse(loginID: loginID, authorizeURL: url.absoluteString,
                                  state: pkce.state)
    }

    public func finishLogin(_ request: LoginFinishRequest) async throws -> RemoteAccount {
        pruneExpiredLogins()
        guard let pending = pendingLogins.removeValue(forKey: request.loginID) else {
            throw ServerError.rejected("no login in flight for that id — it may have expired")
        }
        if let state = request.state, state != pending.pkce.state {
            throw ServerError.rejected("sign-in state did not match; nothing was stored")
        }
        let credential = try await client.exchange(code: request.code, pkce: pending.pkce,
                                                   port: pending.port)
        return try await adopt(credential: credential, label: nil)
    }

    private func pruneExpiredLogins() {
        let cutoff = Date().addingTimeInterval(-Self.loginTTL)
        pendingLogins = pendingLogins.filter { $0.value.startedAt > cutoff }
    }

    // MARK: - Adopt and remove

    public func adopt(_ request: AdoptRequest) async throws -> RemoteAccount {
        if let key = request.apiKey, !key.isEmpty {
            return try await adoptAPIKey(key, label: request.label)
        }
        guard let json = request.credentialJSON,
              let credential = OAuthCredential(json: json) else {
            throw ServerError.rejected("adopt needs either credentialJSON or apiKey")
        }
        return try await adopt(credential: credential, label: request.label)
    }

    private func adopt(credential: OAuthCredential, label: String?) async throws
        -> RemoteAccount {
        let identity = try await client.profile(accessToken: credential.accessToken)
        var account = accounts[identity.uuid]
            ?? RemoteAccount(id: identity.uuid, label: label ?? identity.email ?? identity.uuid)
        if let label, !label.isEmpty { account.label = label }
        account.email = identity.email ?? account.email
        account.organizationUUID = identity.organizationUUID
        account.organizationName = identity.organizationName ?? account.organizationName
        // The profile is the fallback, not an afterthought: a token exchange can hand back
        // a credential with no plan on it, and a session seeded without one is read by
        // Claude Code as having no entitlements at all.
        account.subscriptionType = credential.subscriptionType
            ?? identity.subscriptionType ?? account.subscriptionType
        account.rateLimitTier = credential.rateLimitTier
            ?? identity.rateLimitTier ?? account.rateLimitTier
        account.kind = .subscription
        account.health = .ok
        account.healthDetail = nil

        accounts[account.id] = account
        vault.store(credential, for: account.id)
        persist()
        // Usage is fetched afterwards, not inline. `profile` above already cost up to 15s
        // and a usage call costs another; a client that gives up at 20s while the server
        // has already stored the refresh token leaves both sides holding one lineage.
        Task { await poll(account.id) }
        Log.info("adopted \(account.displayName) (\(account.id))")
        return account
    }

    private func adoptAPIKey(_ key: String, label: String?) async throws -> RemoteAccount {
        _ = try await client.validateAPIKey(key)
        let fingerprint = key.apiKeyFingerprint
        // Matched on the fingerprint, not the id: an API-key account's id is generated
        // locally and differs on every machine, so re-adopting the same key from a second
        // Mac must land on the existing record rather than duplicating it.
        let existing = accounts.values.first { $0.apiKeyFingerprint == fingerprint }
        var account = existing
            ?? RemoteAccount(id: UUID().uuidString, label: label ?? "API key", kind: .apiKey)
        if let label, !label.isEmpty { account.label = label }
        account.kind = .apiKey
        account.health = .ok
        account.healthDetail = nil
        account.apiKeyFingerprint = fingerprint

        accounts[account.id] = account
        try apiKeys.write(key, for: account.id)
        persist()
        Log.info("adopted API key account \(account.displayName)")
        return account
    }

    public func remove(_ accountID: String) throws {
        guard let account = accounts.removeValue(forKey: accountID) else {
            throw ServerError.rejected("no account \(accountID)")
        }
        if account.kind == .apiKey {
            try? apiKeys.delete(accountID)
        } else {
            vault.forget(accountID)
        }
        usage.removeValue(forKey: accountID)
        lastTokenRequest.removeValue(forKey: accountID)
        persist()
        Log.info("removed \(account.displayName)")
    }

    // MARK: - Housekeeping

    /// One tick of the loop: keep every lineage alive, and keep usage fresh enough for
    /// clients to rank against.
    public func tick() async {
        pruneExpiredLogins()
        await vault.refreshExpiring(
            accountIDs: accounts.values.filter { $0.kind == .subscription }.map(\.id))
        await pollDueAccounts()
    }

    private func pollDueAccounts() async {
        let now = Date()
        let due = accounts.values.filter { account in
            guard account.kind == .subscription, account.health != .needsRelogin else {
                return false
            }
            guard let next = usage[account.id]?.nextPollAt else { return true }
            return next <= now
        }
        for account in due { await poll(account.id) }
    }

    private func poll(_ accountID: String) async {
        guard let token = vault.credential(for: accountID)?.accessToken else { return }
        do {
            record(.success(try await client.usage(accessToken: token)), for: accountID)
        } catch {
            record(.failure(error), for: accountID)
        }
    }

    private func record(_ result: Result<[UsageWindow], Error>, for accountID: String) {
        let previous = usage[accountID]
        var snapshot = previous ?? UsageSnapshot()
        var rateLimited = false

        switch result {
        case .success(let windows):
            snapshot.windows = windows
            snapshot.fetchedAt = Date()
            snapshot.lastEndpointFetchAt = Date()
            snapshot.lastError = nil
        case .failure(let error):
            snapshot.lastError = error.localizedDescription
            rateLimited = (error as? OAuthError)?.statusCode == 429
        }
        let plan = PollPolicy.plan(
            isInUse: lastTokenRequest[accountID].map {
                Date().timeIntervalSince($0) < Self.inUseWindow
            } ?? false,
            previous: previous, current: snapshot,
            threshold: Self.pollThreshold, rateLimited: rateLimited)
        snapshot.nextPollAt = plan.nextPollAt
        usage[accountID] = snapshot
    }

    private func recordRefreshFailure(_ accountID: String, _ error: OAuthError) {
        guard error.isPermanent else { return }
        accounts[accountID]?.health = .needsRelogin
        accounts[accountID]?.healthDetail = error.localizedDescription
        persist()
        Log.warn("\(accountID) needs re-login: \(error.localizedDescription)")
    }

    private func recordPersistFailure(_ accountID: String, _ error: Error) {
        accounts[accountID]?.healthDetail =
            "a rotated credential could not be saved: \(error.localizedDescription)"
        persist()
        Log.error("could not persist the rotated credential for \(accountID) — a restart "
                  + "will come back with a dead refresh token: \(error)")
    }

    private func markHealthy(_ accountID: String) {
        guard accounts[accountID]?.health == .needsRelogin else { return }
        accounts[accountID]?.health = .ok
        accounts[accountID]?.healthDetail = nil
        persist()
    }

    private func persist() {
        JSONStore.save(list(), to: accountsFile)
    }
}
