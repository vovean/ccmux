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
/// against Claude Code 2.1.238: it reports `loggedIn: true` for the right account with
/// such a credential. Inference is unaffected because the proxy substitutes the real
/// token per request, and the seeded token is refreshed in place so Claude Code's own
/// direct calls keep working too.
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
    private var inFlight: [String: Task<OAuthCredential?, Never>] = [:]
    private let client: OAuthClient

    /// Refresh this far ahead of expiry so a request rarely has to wait on one.
    private static let refreshLead: TimeInterval = 10 * 60
    private static let blockingRefreshTimeout: TimeInterval = 20

    public init(client: OAuthClient = OAuthClient()) {
        self.client = client
    }

    public func load(accountIDs: [String]) {
        for id in accountIDs {
            if let credential = try? AccountCredentialStore.read(id) {
                lock.lock(); credentials[id] = credential; lock.unlock()
            }
        }
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
            try AccountCredentialStore.write(credential, for: accountID)
        } catch {
            // One retry: the usual cause is a transient `security` timeout under
            // contention, and losing a rotation costs a re-login.
            do {
                try AccountCredentialStore.write(credential, for: accountID)
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
        inFlight.removeValue(forKey: accountID)?.cancel()
        lock.unlock()
        try? AccountCredentialStore.delete(accountID)
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
        if let running = existingRefresh(accountID) { return await running.value }

        let task = Task<OAuthCredential?, Never> { [weak self] in
            guard let self, let existing = self.credential(for: accountID) else { return nil }
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
        lock.lock(); inFlight[accountID] = task; lock.unlock()
        let result = await task.value
        lock.lock(); inFlight.removeValue(forKey: accountID); lock.unlock()
        return result
    }

    private func existingRefresh(_ accountID: String) -> Task<OAuthCredential?, Never>? {
        lock.lock(); defer { lock.unlock() }
        return inFlight[accountID]
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
