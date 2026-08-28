import Foundation

/// Owns every account's credential and hands the proxy a usable bearer token.
///
/// ccmux is the *only* refresher, by construction rather than by convention. Anthropic
/// rotates refresh tokens, so two independent refreshers on one lineage means whichever
/// refreshes second is told `invalid_grant` and is logged out — and a session's Claude
/// Code would otherwise be the second refresher.
///
/// The way out is `neuteredForSession`: a session namespace is seeded with a live access
/// token, an expiry far enough out that Claude Code never schedules a refresh, and no
/// refresh token at all, so it cannot rotate the lineage even if it tried. Verified
/// against Claude Code 2.1.238: `claude auth status` in such a namespace reports
/// `loggedIn: true`, and an unseeded namespace reports not logged in, so the credential
/// really is the one being used. Inference is unaffected because the proxy substitutes
/// the real token per request, and the seeded token is refreshed in place so Claude
/// Code's own calls to the profile and usage endpoints keep working.
public final class TokenVault {
    /// Called when a refresh fails. Permanent failures are the re-login signal.
    public var onRefreshFailure: ((String, OAuthError) -> Void)?
    /// Called when a rotated credential could not be written to the Keychain. That is a
    /// real credential-loss risk: the rotation is live on Anthropic's side but only in
    /// memory here, so a restart would come back holding a dead refresh token.
    public var onPersistFailure: ((String, Error) -> Void)?
    /// Called when a credential changes, so the UI can reflect a healthy account.
    public var onCredentialChanged: ((String, OAuthCredential) -> Void)?
    /// Called after a refresh so live session namespaces can be re-seeded with the new
    /// access token, keeping Claude Code's own profile and usage calls working.
    public var onRefreshed: ((String, OAuthCredential) -> Void)?

    private let lock = NSLock()
    private var credentials: [String: OAuthCredential] = [:]
    private var inFlight: [String: (id: UInt64, task: Task<OAuthCredential?, Never>)] = [:]
    private var nextRefreshID: UInt64 = 0
    /// Swappable so an upstream-proxy change reaches token refresh too, which is the one
    /// call that must not keep going direct on a machine that needs the proxy.
    private var client: OAuthClient
    /// Keychain on a Mac, a sealed file on the server. The coalescing below is the part
    /// that must not be reimplemented per platform, which is why this is a parameter.
    private let secrets: SecretStore
    /// Set when this Mac has handed its accounts to a ccmuxd. Delegated accounts are
    /// renewed by asking the server for a fresh access token rather than by running a
    /// refresh grant, because the server is the sole holder of the lineage.
    private var remote: RemoteTokenSource?
    private var delegated: Set<String> = []

    /// Refresh this far ahead of expiry so a request rarely has to wait on one.
    private static let refreshLead: TimeInterval = 10 * 60
    private static let blockingRefreshTimeout: TimeInterval = 20

    public init(client: OAuthClient, secrets: SecretStore) {
        self.client = client
        self.secrets = secrets
    }

    public func setClient(_ client: OAuthClient) {
        lock.lock(); self.client = client; lock.unlock()
    }

    /// Points delegated accounts at a server. Everything else — coalescing, persistence,
    /// the failure callbacks — is unchanged, which is the reason this lives here rather
    /// than in a parallel implementation.
    public func setRemote(_ remote: RemoteTokenSource?, delegated ids: Set<String>) {
        lock.lock()
        self.remote = remote
        // `ids` is stored as given even when `remote` is nil. Clearing it here would let a
        // delegated account fall through to a local refresh grant, and a delegated
        // credential carries no refresh token — so the grant fails permanently and a
        // perfectly healthy account is marked as needing re-login. Reachable from nothing
        // worse than a Keychain read hiccup at launch. Disconnecting passes an empty set
        // explicitly, which is the only way to stop delegating.
        self.delegated = ids
        lock.unlock()
    }

    public func isDelegated(_ accountID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return delegated.contains(accountID)
    }

    private func remoteSource(for accountID: String) -> RemoteTokenSource? {
        lock.lock(); defer { lock.unlock() }
        return delegated.contains(accountID) ? remote : nil
    }

    /// Whether a delegated account currently has somewhere to renew from.
    public func hasRemote(for accountID: String) -> Bool {
        remoteSource(for: accountID) != nil
    }

    public func load(accountIDs: [String]) {
        for id in accountIDs {
            if let raw = try? secrets.read(id), let credential = OAuthCredential(json: raw) {
                lock.lock(); credentials[id] = credential; lock.unlock()
            }
        }
    }

    /// Every account the secret store holds a credential for, whatever the accounts file
    /// happens to say.
    public func storedAccountIDs() -> [String] {
        (try? secrets.keys()) ?? []
    }

    public func credential(for accountID: String) -> OAuthCredential? {
        lock.lock(); defer { lock.unlock() }
        return credentials[accountID]
    }

    public func store(_ credential: OAuthCredential, for accountID: String) {
        lock.lock()
        credentials[accountID] = credential
        lock.unlock()
        do {
            try secrets.write(credential.jsonString(), for: accountID)
        } catch {
            // One retry: the usual cause is a transient `security` timeout under
            // contention, and losing a rotation costs a re-login.
            do {
                try secrets.write(credential.jsonString(), for: accountID)
            } catch {
                Log.error("could not persist credential for \(accountID): \(error)")
                onPersistFailure?(accountID, error)
            }
        }
        onCredentialChanged?(accountID, credential)
    }

    public func forget(_ accountID: String) {
        lock.lock()
        credentials.removeValue(forKey: accountID)
        inFlight.removeValue(forKey: accountID)?.task.cancel()
        lock.unlock()
        try? secrets.delete(accountID)
    }

    /// The token to put on the wire right now. Called off the main thread by the proxy.
    public func bearerToken(for accountID: String) -> String? {
        guard let credential = credential(for: accountID) else { return nil }
        if !credential.isAccessTokenExpired { return credential.accessToken }

        let semaphore = DispatchSemaphore(value: 0)
        var refreshed: String?
        Task { [weak self] in
            refreshed = await self?.refresh(accountID)?.accessToken
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + Self.blockingRefreshTimeout)
        // Falling back to the expired token beats failing the request outright: the
        // server may still honour it inside its own grace period.
        return refreshed ?? credential.accessToken
    }

    /// A usable token if one is already in hand, never blocking. Returns nil rather than
    /// refreshing, and kicks a refresh off in the background instead.
    ///
    /// For callers that must not block: the proxy's failover decision runs on the
    /// URLSession delegate queue, which is shared by every session, so a blocking refresh
    /// there stalls unrelated streams mid-answer.
    public func cachedBearerToken(for accountID: String) -> String? {
        guard let credential = credential(for: accountID) else { return nil }
        guard !credential.isAccessTokenExpired else {
            Task { [weak self] in await self?.refresh(accountID) }
            return nil
        }
        return credential.accessToken
    }

    /// Refreshes ahead of expiry so `bearerToken` almost never has to block.
    public func refreshExpiring(accountIDs: [String]) async {
        for id in accountIDs {
            guard let credential = credential(for: id), let expiresAt = credential.expiresAt,
                  Date().addingTimeInterval(Self.refreshLead) >= expiresAt else { continue }
            _ = await refresh(id)
        }
    }

    /// Runs the refresh grant, coalescing concurrent callers onto one attempt so the
    /// loser gets the same rotated credential rather than nothing.
    @discardableResult
    public func refresh(_ accountID: String) async -> OAuthCredential? {
        let claim = claimRefresh(accountID)
        let result = await claim.task.value
        release(accountID, id: claim.id)
        return result
    }

    /// Look-up and insert must be one critical section. Two callers that each saw an
    /// empty slot would both POST the same refresh token, and because Anthropic rotates
    /// them the loser gets `invalid_grant` — which marks a perfectly healthy account as
    /// needing re-login. The 20-second timer's own ticks can overlap (a usage fetch
    /// alone allows 15s), and `SessionManager.seed` refreshes from a control-socket
    /// thread, so this is reachable without anything unusual happening.
    private func claimRefresh(_ accountID: String)
        -> (id: UInt64, task: Task<OAuthCredential?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let running = inFlight[accountID] { return running }

        nextRefreshID += 1
        let id = nextRefreshID
        let task = Task<OAuthCredential?, Never> { [weak self] in
            guard let self else { return nil }
            if self.isDelegated(accountID) {
                guard let remote = self.remoteSource(for: accountID) else {
                    // Deliberately not falling back to a local grant: see `setRemote`.
                    // Transient, so the account is not marked as needing re-login for what
                    // is only an unreachable server.
                    let error = OAuthError.transient(
                        "the account server is unreachable, so \(accountID) cannot be renewed")
                    Log.warn(error.localizedDescription)
                    self.onRefreshFailure?(accountID, error)
                    return nil
                }
                return await self.renewFromServer(accountID, remote)
            }
            guard let existing = self.credential(for: accountID) else { return nil }
            do {
                let rotated = try await self.client.refresh(existing)
                self.store(rotated, for: accountID)
                self.onRefreshed?(accountID, rotated)
                Log.info("refreshed credential for account \(accountID)")
                return rotated
            } catch let error as OAuthError {
                Log.warn("refresh failed for account \(accountID): "
                         + error.localizedDescription)
                self.onRefreshFailure?(accountID, error)
                return nil
            } catch {
                self.onRefreshFailure?(accountID, OAuthError.transient("\(error)"))
                return nil
            }
        }
        inFlight[accountID] = (id, task)
        return (id, task)
    }

    /// Asks the server for a fresh access token. The grant carries no refresh token, so
    /// what lands in the store cannot rotate anything — which is exactly the property
    /// that makes delegating safe.
    private func renewFromServer(_ accountID: String,
                                 _ remote: RemoteTokenSource) async -> OAuthCredential? {
        do {
            let grant = try await remote.grant(for: accountID)
            // `isUsable`, not merely non-nil: a grant can carry a token that expired
            // before it arrived, and storing that over what we hold gains nothing.
            guard grant.isUsable, let credential = grant.credential() else {
                throw OAuthError.badResponse("the server returned no usable access token")
            }
            store(credential, for: accountID)
            onRefreshed?(accountID, credential)
            Log.info("renewed \(accountID) from ccmuxd")
            return credential
        } catch let error as RemoteTokenError {
            // Permanent on purpose: the server holds no working credential, so only a
            // fresh sign-in recovers it. Reporting this as transient would leave the
            // account looking healthy while every request on it answered 401.
            Log.warn("ccmuxd cannot serve \(accountID): " + error.localizedDescription)
            onRefreshFailure?(accountID, .invalidGrant(error.localizedDescription))
            return nil
        } catch let error as OAuthError {
            Log.warn("ccmuxd could not renew \(accountID): " + error.localizedDescription)
            onRefreshFailure?(accountID, error)
            return nil
        } catch {
            Log.warn("ccmuxd could not renew \(accountID): \(error)")
            onRefreshFailure?(accountID, OAuthError.transient("\(error)"))
            return nil
        }
    }

    /// Only the caller that created the entry may clear it, or a finishing refresh could
    /// delete a newer one's slot and reopen the race it just closed.
    private func release(_ accountID: String, id: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if inFlight[accountID]?.id == id { inFlight.removeValue(forKey: accountID) }
    }
}

extension OAuthCredential {
    /// How far out a seeded credential's expiry is pushed. Long enough that Claude Code
    /// never schedules a refresh over any realistic session.
    static let seededLifetime: TimeInterval = 365 * 86400

    /// The form written into a session's Keychain namespace: a live access token that
    /// Claude Code cannot refresh and does not think needs refreshing.
    ///
    /// Dropping the refresh token is the load-bearing part. Leaving it would let a
    /// session's Claude Code rotate the lineage on its own schedule, and whichever
    /// refresher lost that race — ccmux, or another session on the same account — would
    /// be permanently logged out.
    public func neuteredForSession(now: Date = Date()) -> OAuthCredential {
        var copy = self
        copy.refreshToken = nil
        copy.refreshTokenExpiresAt = nil
        copy.expiresAt = now.addingTimeInterval(Self.seededLifetime)
        return copy
    }
}
