import Foundation

/// Owns every account's credential and hands the proxy a usable bearer token.
///
/// Refresh ownership is the delicate part. Anthropic rotates refresh tokens, so two
/// independent refreshers on one lineage means whichever refreshes second is told
/// `invalid_grant` and is logged out. Claude Code refreshes the credential in its own
/// session namespace and we deliberately let it, so:
///
/// - while a session's namespace owns an account's lineage, we *adopt* whatever
///   Claude Code rotated to instead of refreshing ourselves;
/// - we only run the refresh grant for an account no live session owns;
/// - a failed refresh with a permanent cause marks the account as needing re-login
///   rather than being retried into the ground.
public final class TokenVault {
    /// Called when a refresh fails. Permanent failures are the re-login signal.
    public var onRefreshFailure: ((String, OAuthError) -> Void)?
    /// Called when a credential changes, so the UI can reflect a healthy account.
    public var onCredentialChanged: ((String, OAuthCredential) -> Void)?
    /// Resolves the namespace whose Claude Code owns this account's lineage, if any.
    public var lineageOwner: ((String) -> URL?)?

    private let lock = NSLock()
    private var credentials: [String: OAuthCredential] = [:]
    private var namespaceCache: [String: (credential: OAuthCredential, readAt: Date)] = [:]
    private var inFlight: Set<String> = []
    private let client: OAuthClient

    /// Refresh this far ahead of expiry so a request rarely has to wait on one.
    private static let refreshLead: TimeInterval = 10 * 60
    /// Keychain reads are cheap but not free; a session's namespace item changes only
    /// when Claude Code refreshes, which is roughly every eight hours.
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
            Log.error("could not persist credential for \(accountID): \(error)")
        }
        onCredentialChanged?(accountID, credential)
    }

    public func forget(_ accountID: String) {
        lock.lock()
        credentials.removeValue(forKey: accountID)
        namespaceCache.removeValue(forKey: accountID)
        lock.unlock()
        try? AccountCredentialStore.delete(accountID)
    }

    /// The token to put on the wire right now. Blocks for a refresh only when the
    /// cached token is already expired; called off the main thread by the proxy.
    public func bearerToken(for accountID: String) -> String? {
        if let adopted = adoptFromNamespaceIfFresher(accountID) { return adopted }

        guard let credential = credential(for: accountID) else { return nil }
        if !credential.isAccessTokenExpired { return credential.accessToken }

        let semaphore = DispatchSemaphore(value: 0)
        var refreshed: String?
        Task { [weak self] in
            refreshed = await self?.refresh(accountID)?.accessToken
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + Self.blockingRefreshTimeout)
        // Falling back to the expired token is better than failing the request
        // outright: the server may still honour it inside its own grace, and a 401
        // gives Claude Code a chance to recover on its own.
        return refreshed ?? credential.accessToken
    }

    /// Refreshes ahead of expiry for the accounts that matter, so `bearerToken` almost
    /// never has to block.
    public func refreshExpiring(accountIDs: [String]) async {
        for id in accountIDs {
            _ = adoptFromNamespaceIfFresher(id)
            guard let credential = credential(for: id) else { continue }
            guard let expiresAt = credential.expiresAt else { continue }
            guard Date().addingTimeInterval(Self.refreshLead) >= expiresAt else { continue }
            // A session's Claude Code owns this lineage and will rotate it itself;
            // racing it is exactly how one of the two copies gets invalidated.
            if lineageOwner?(id) != nil { continue }
            _ = await refresh(id)
        }
    }

    /// Claims the refresh slot for an account, returning the credential to refresh, or
    /// nil when another refresh is already running for it.
    private func beginRefresh(_ accountID: String) -> OAuthCredential? {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(accountID), let existing = credentials[accountID] else {
            return nil
        }
        inFlight.insert(accountID)
        return existing
    }

    private func endRefresh(_ accountID: String) {
        lock.lock()
        inFlight.remove(accountID)
        lock.unlock()
    }

    @discardableResult
    public func refresh(_ accountID: String) async -> OAuthCredential? {
        guard let existing = beginRefresh(accountID) else { return nil }
        defer { endRefresh(accountID) }
        do {
            let rotated = try await client.refresh(existing)
            store(rotated, for: accountID)
            Log.info("refreshed credential for account \(accountID)")
            return rotated
        } catch let error as OAuthError {
            Log.warn("refresh failed for account \(accountID): \(error.localizedDescription)")
            onRefreshFailure?(accountID, error)
            return nil
        } catch {
            let wrapped = OAuthError.transient("\(error)")
            onRefreshFailure?(accountID, wrapped)
            return nil
        }
    }

    /// Picks up a credential Claude Code rotated inside the owning session's namespace.
    @discardableResult
    public func adoptFromNamespaceIfFresher(_ accountID: String) -> String? {
        guard let namespace = lineageOwner?(accountID) else { return nil }

        lock.lock()
        let cached = namespaceCache[accountID]
        lock.unlock()

        var fromNamespace: OAuthCredential?
        if let cached, Date().timeIntervalSince(cached.readAt) < Self.namespaceCacheTTL {
            fromNamespace = cached.credential
        } else if let read = try? ClaudeCredentialStore.read(namespace: namespace) {
            fromNamespace = read
            lock.lock()
            namespaceCache[accountID] = (read, Date())
            lock.unlock()
        }

        guard let fromNamespace, !fromNamespace.isAccessTokenExpired else { return nil }
        let mine = credential(for: accountID)
        if mine?.accessToken == fromNamespace.accessToken { return fromNamespace.accessToken }

        // Claude Code rotated it; that generation is now the live one.
        Log.info("adopted Claude Code's rotated credential for account \(accountID)")
        store(fromNamespace, for: accountID)
        return fromNamespace.accessToken
    }

    public func invalidateNamespaceCache(_ accountID: String) {
        lock.lock()
        namespaceCache.removeValue(forKey: accountID)
        lock.unlock()
    }
}
