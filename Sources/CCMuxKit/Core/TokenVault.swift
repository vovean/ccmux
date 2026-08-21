import Foundation

/// Owns every account's credential and hands the proxy a usable bearer token.
///
/// Refresh ownership is the delicate part. Anthropic rotates refresh tokens, so two
/// independent refreshers on one lineage means whichever refreshes second is told
/// `invalid_grant` and is logged out. Claude Code refreshes the credential in its own
/// session namespace and we deliberately let it, so the rule is:
///
/// - while *any* live session holds a namespace for an account, ccmux never runs the
///   refresh grant for it — it adopts whatever Claude Code rotated to instead;
/// - ccmux only runs the grant for an account no live session holds;
/// - adoption looks at every live namespace, not just the one flagged as lineage
///   owner: `ownsLineage` is ccmux-side bookkeeping and cannot stop a second Claude
///   Code from refreshing a credential it was seeded with, so a rotation by a
///   non-owner must still be picked up or it would be deleted with its namespace;
/// - a failed refresh with a permanent cause marks the account as needing re-login
///   rather than being retried into the ground.
public final class TokenVault {
    /// Called when a refresh fails. Permanent failures are the re-login signal.
    public var onRefreshFailure: ((String, OAuthError) -> Void)?
    /// Called when a rotated credential could not be written to the Keychain. That is
    /// a real credential-loss risk: the rotation is live on Anthropic's side but only
    /// in memory here, so a restart would come back holding a dead refresh token.
    public var onPersistFailure: ((String, Error) -> Void)?
    /// Called when a credential changes, so the UI can reflect a healthy account.
    public var onCredentialChanged: ((String, OAuthCredential) -> Void)?
    /// Namespaces of every live session using this account, owner first.
    public var liveNamespaces: ((String) -> [URL])?
    /// Called after adopting a rotation so sibling namespaces can be re-seeded; their
    /// Claude Code is otherwise left holding a refresh token that is now dead.
    public var onAdopted: ((String, OAuthCredential) -> Void)?

    private let lock = NSLock()
    private var credentials: [String: OAuthCredential] = [:]
    private var namespaceReadAt: [URL: Date] = [:]
    private var inFlight: [String: Task<OAuthCredential?, Never>] = [:]
    private let client: OAuthClient

    /// Refresh this far ahead of expiry so a request rarely has to wait on one.
    private static let refreshLead: TimeInterval = 10 * 60
    /// Namespace items only change when Claude Code refreshes, roughly every eight
    /// hours, so re-reading them on every request would be pure subprocess cost.
    private static let namespaceCacheTTL: TimeInterval = 15
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
        if let adopted = adoptFromNamespaces(accountID) { return adopted }

        guard let credential = credential(for: accountID) else { return nil }
        if !credential.isAccessTokenExpired { return credential.accessToken }

        // A live session's Claude Code owns this lineage and refreshes it on its own
        // schedule. Running the grant here would rotate the token underneath it and
        // log that session out mid-flight, so serve the stale token instead: the 401
        // it earns is exactly what makes Claude Code refresh, and the next request
        // adopts the result.
        if !(liveNamespaces?(accountID) ?? []).isEmpty {
            return credential.accessToken
        }

        let semaphore = DispatchSemaphore(value: 0)
        var refreshed: String?
        Task { [weak self] in
            refreshed = await self?.refresh(accountID)?.accessToken
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + Self.blockingRefreshTimeout)
        return refreshed ?? credential.accessToken
    }

    /// Refreshes ahead of expiry for the accounts that matter, so `bearerToken` almost
    /// never has to block.
    public func refreshExpiring(accountIDs: [String]) async {
        for id in accountIDs {
            // Ownership decides the whole strategy, so branch on it first rather than
            // computing expiry arithmetic that an owned account will never use.
            if !(liveNamespaces?(id) ?? []).isEmpty {
                _ = adoptFromNamespaces(id)
                continue
            }
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

    /// Picks up a credential Claude Code rotated in any of this account's live session
    /// namespaces, newest expiry wins.
    ///
    /// Every live namespace is read, not just the one flagged `ownsLineage`: that flag
    /// is ccmux bookkeeping and cannot stop a second Claude Code from refreshing a
    /// credential it was seeded with, so a rotation by a non-owner has to be picked up
    /// here or it would be deleted along with its namespace.
    @discardableResult
    public func adoptFromNamespaces(_ accountID: String) -> String? {
        let namespaces = liveNamespaces?(accountID) ?? []
        guard !namespaces.isEmpty else { return nil }
        let mine = credential(for: accountID)

        var freshest: OAuthCredential?
        var readAny = false
        for namespace in namespaces {
            // Cached per namespace, so a reassignment changes the key and stale
            // entries become unreachable rather than needing explicit invalidation.
            if let readAt = lastRead(namespace),
               Date().timeIntervalSince(readAt) < Self.namespaceCacheTTL { continue }
            readAny = true
            markRead(namespace)
            guard let candidate = (try? ClaudeCredentialStore.read(namespace: namespace)) ?? nil,
                  !candidate.isAccessTokenExpired else { continue }
            if let best = freshest,
               (best.expiresAt ?? .distantPast) >= (candidate.expiresAt ?? .distantPast) {
                continue
            }
            freshest = candidate
        }

        guard readAny else {
            guard let mine, !mine.isAccessTokenExpired else { return nil }
            return mine.accessToken
        }
        guard let freshest else { return nil }
        guard freshest.accessToken != mine?.accessToken else { return freshest.accessToken }

        Log.info("adopted Claude Code's rotated credential for account \(accountID)")
        store(freshest, for: accountID)
        onAdopted?(accountID, freshest)
        return freshest.accessToken
    }

    private func lastRead(_ namespace: URL) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return namespaceReadAt[namespace]
    }

    private func markRead(_ namespace: URL) {
        lock.lock(); namespaceReadAt[namespace] = Date(); lock.unlock()
    }

}
