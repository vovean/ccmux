import Foundation

public enum SessionError: Error, LocalizedError {
    case noEligibleAccount(policy: String)
    case unknownPolicy(String)
    case noCredential(String)
    case seedFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEligibleAccount(let policy):
            return "No account has headroom left for the “\(policy)” policy"
        case .unknownPolicy(let name):
            return "No policy named “\(name)”"
        case .noCredential(let id):
            return "No stored credential for account \(id)"
        case .seedFailed(let reason):
            return "Could not prepare the session credential: \(reason)"
        }
    }
}

/// Creates, reassigns and tears down sessions: the namespace Claude Code reads its
/// credential from, and the proxy its requests go through.
public final class SessionManager {
    private let store: Store
    private let vault: TokenVault
    private var proxies: [String: SessionProxy] = [:]
    private let lock = NSLock()

    /// Called with every proxied response so usage can be updated and exhaustion
    /// detected. Fires off the main thread.
    public var onObservation: ((SessionProxy.Observation, String) -> Void)?

    public init(store: Store, vault: TokenVault) {
        self.store = store
        self.vault = vault
    }

    /// The namespace whose Claude Code is allowed to rotate this account's lineage.
    public func lineageOwner(accountID: String) -> URL? {
        store.allSessions()
            .filter { $0.accountID == accountID && $0.ownsLineage }
            .first { ClaudeSessions.isAlive($0.pid) }?
            .namespaceDir
    }

    // MARK: - Creation

    public func createSession(policyName: String, cwd: String, pid: Int32) throws
        -> ControlSessionInfo {
        let settings = store.currentSettings()
        guard let policy = settings.policy(named: policyName) else {
            throw SessionError.unknownPolicy(policyName)
        }
        let accounts = store.allAccounts()
        guard let choice = PolicyEngine.pick(accounts: accounts, usage: store.allUsage(),
                                             policy: policy) else {
            throw SessionError.noEligibleAccount(policy: policyName)
        }
        return try createSession(accountID: choice.accountID, policyName: policyName,
                                 cwd: cwd, pid: pid)
    }

    public func createSession(accountID: String, policyName: String, cwd: String,
                              pid: Int32) throws -> ControlSessionInfo {
        guard let account = store.account(accountID) else {
            throw SessionError.noCredential(accountID)
        }
        let sessionID = UUID().uuidString.lowercased()
        let namespace = Paths.namespace(sessionID)
        try FileManager.default.createDirectory(at: namespace,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        // Nobody owns this account's lineage yet, so this session's Claude Code may
        // refresh it and we will adopt the result. Otherwise it boots on a token we
        // keep fresh and never needs to refresh at all.
        let ownsLineage = lineageOwner(accountID: accountID) == nil
        var record = SessionRecord(id: sessionID, pid: pid, port: 0, accountID: accountID,
                                   policyName: policyName, cwd: cwd,
                                   autoSwitch: store.currentSettings().autoSwitch != .off,
                                   ownsLineage: ownsLineage)

        do {
            try seed(accountID: accountID, into: namespace)
        } catch {
            try? FileManager.default.removeItem(at: namespace)
            throw SessionError.seedFailed("\(error)")
        }

        let proxy = makeProxy(sessionID: sessionID, desiredPort: nil)

        do {
            record.port = try proxy.start()
        } catch {
            try? ClaudeCredentialStore.clear(namespace: namespace)
            try? FileManager.default.removeItem(at: namespace)
            throw error
        }

        lock.lock(); proxies[sessionID] = proxy; lock.unlock()
        store.upsert(record)
        Log.info("session \(sessionID) pid=\(pid) account=\(account.displayName) "
                 + "policy=\(policyName) port=\(record.port) ownsLineage=\(ownsLineage)")

        return ControlSessionInfo(sessionID: sessionID, namespaceDir: namespace.path,
                                  port: record.port, accountID: accountID,
                                  accountLabel: account.displayName,
                                  policyName: policyName, pid: pid)
    }

    private func makeProxy(sessionID: String, desiredPort: UInt16?) -> SessionProxy {
        SessionProxy(
            sessionID: sessionID,
            desiredPort: desiredPort,
            tokenProvider: { [weak self] in
                guard let self,
                      let current = self.store.session(sessionID),
                      let token = self.vault.bearerToken(for: current.accountID)
                else { return nil }
                return (current.accountID, token)
            },
            observer: { [weak self] observation in
                self?.onObservation?(observation, sessionID)
            })
    }

    /// Writes the account's credential where Claude Code will look for it, with a
    /// non-expired access token so startup never has to refresh.
    private func seed(accountID: String, into namespace: URL) throws {
        guard var credential = vault.credential(for: accountID) else {
            throw SessionError.noCredential(accountID)
        }
        if credential.isAccessTokenExpired {
            let semaphore = DispatchSemaphore(value: 0)
            var refreshed: OAuthCredential?
            Task { [vault] in
                refreshed = await vault.refresh(accountID)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            if let refreshed { credential = refreshed }
        }
        try ClaudeCredentialStore.write(credential, namespace: namespace)
    }

    // MARK: - Reassignment

    /// Points a session at a different account. The proxy reads the assignment per
    /// request, so this takes effect on the session's very next call.
    public func assign(sessionID: String, accountID: String) throws {
        guard store.account(accountID) != nil else {
            throw SessionError.noCredential(accountID)
        }
        guard let existing = store.session(sessionID) else {
            throw SessionError.noCredential(sessionID)
        }
        guard existing.accountID != accountID else { return }

        let ownsLineage = lineageOwner(accountID: accountID) == nil
        store.mutateSession(sessionID) {
            $0.accountID = accountID
            $0.ownsLineage = ownsLineage
        }
        // Re-seed so a restart of this session boots on the new account too.
        try? seed(accountID: accountID, into: Paths.namespace(sessionID))
        vault.invalidateNamespaceCache(accountID)
        Log.info("session \(sessionID) reassigned to account \(accountID)")
    }

    // MARK: - Teardown

    public func endSession(_ sessionID: String) {
        lock.lock()
        let proxy = proxies.removeValue(forKey: sessionID)
        lock.unlock()
        proxy?.stop()

        if let record = store.session(sessionID) {
            // Claude Code may have rotated the credential; take the newest generation
            // before deleting the namespace it lives in.
            if record.ownsLineage,
               let rotated = try? ClaudeCredentialStore.read(namespace: record.namespaceDir),
               rotated.accessToken != vault.credential(for: record.accountID)?.accessToken {
                vault.store(rotated, for: record.accountID)
            }
            try? ClaudeCredentialStore.clear(namespace: record.namespaceDir)
            try? FileManager.default.removeItem(at: record.namespaceDir)
            vault.invalidateNamespaceCache(record.accountID)
        }
        store.removeSession(sessionID)
        Log.info("session \(sessionID) ended")
    }

    /// Ends sessions whose claude process is gone.
    public func reap() {
        for record in store.allSessions() where !ClaudeSessions.isAlive(record.pid) {
            endSession(record.id)
        }
    }

    /// Removes namespace directories with no matching session record, which is what a
    /// crash leaves behind.
    public func sweepOrphanNamespaces() {
        let live = Set(store.allSessions().map(\.id))
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: Paths.namespaceRoot.path) else { return }
        for name in names where !live.contains(name) {
            let dir = Paths.namespace(name)
            try? ClaudeCredentialStore.clear(namespace: dir)
            try? FileManager.default.removeItem(at: dir)
            Log.info("swept orphan namespace \(name)")
        }
    }

    public func stopAll() {
        lock.lock()
        let all = proxies
        proxies.removeAll()
        lock.unlock()
        for proxy in all.values { proxy.stop() }
    }

    /// Rebinds proxies for sessions that outlived a previous run of the app.
    ///
    /// The port is baked into each session's ANTHROPIC_BASE_URL, so recovery means
    /// re-binding the same port. A session whose port is no longer available cannot be
    /// rescued and is ended, which is at least an honest failure.
    public func restoreProxies() {
        for record in store.allSessions() {
            guard ClaudeSessions.isAlive(record.pid) else {
                endSession(record.id)
                continue
            }
            let proxy = makeProxy(sessionID: record.id, desiredPort: record.port)
            do {
                let port = try proxy.start()
                lock.lock(); proxies[record.id] = proxy; lock.unlock()
                Log.info("restored proxy for session \(record.id) on port \(port)")
            } catch {
                Log.warn("could not rebind port \(record.port) for session "
                         + "\(record.id): \(error.localizedDescription)")
                endSession(record.id)
            }
        }
    }
}
