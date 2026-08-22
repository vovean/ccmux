import Foundation

public enum SessionError: Error, LocalizedError {
    case noEligibleAccount(policy: String)
    case unknownPolicy(String)
    case unknownAccount(String)
    case unknownSession(String)
    case noCredential(String)
    case seedFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEligibleAccount(let policy):
            return "No account has headroom left for the “\(policy)” policy"
        case .unknownPolicy(let name):
            return "No policy named “\(name)”"
        case .unknownAccount(let id):
            return "No account with id \(id)"
        case .unknownSession(let id):
            return "No session with id \(id)"
        case .noCredential(let id):
            return "No stored credential for account \(id); sign in again"
        case .seedFailed(let reason):
            return "Could not prepare the session credential: \(reason)"
        }
    }
}

public enum ReassignOutcome: Equatable {
    case switched(from: String, to: String)
    case disabled
    case noneEligible
    case failed(String)
}

/// Creates, reassigns and tears down sessions: the namespace Claude Code reads its
/// credential from, and the proxy its requests go through.
public final class SessionManager: SessionRouting {
    private let store: Store
    private let vault: TokenVault
    private var proxies: [String: SessionProxy] = [:]
    private let lock = NSLock()
    /// Creating a session reads the session table to decide lineage ownership and then
    /// writes to it. Two shims racing would both read "nobody owns this account" and
    /// both claim ownership, so the whole decision is serialized.
    private let createLock = NSLock()

    /// Called with every proxied response so usage can be updated and exhaustion
    /// detected. Fires off the main thread.
    public var onObservation: ((SessionProxy.Observation, String) -> Void)?

    public init(store: Store, vault: TokenVault) {
        self.store = store
        self.vault = vault
        vault.onRefreshed = { [weak self] accountID, credential in
            self?.reseedNamespaces(accountID: accountID, credential: credential)
        }
    }

    /// Namespaces of every live session on this account.
    private func liveNamespaces(accountID: String) -> [URL] {
        store.sessions(forAccount: accountID)
            .filter { ClaudeSessions.isAlive($0.pid) }
            .map(\.namespaceDir)
    }

    /// Keeps each live session's seeded credential current after a refresh.
    ///
    /// Not required for inference — the proxy substitutes the real token per request —
    /// but Claude Code makes its own calls to the profile and usage endpoints straight
    /// to Anthropic, and it re-reads the Keychain for those. Re-seeding is what keeps
    /// the account name and `/usage` inside a long session from going stale.
    private func reseedNamespaces(accountID: String, credential: OAuthCredential) {
        let seeded = credential.neuteredForSession()
        for namespace in liveNamespaces(accountID: accountID) {
            do {
                try ClaudeCredentialStore.write(seeded, namespace: namespace)
            } catch {
                Log.warn("could not re-seed \(namespace.lastPathComponent) for "
                         + "\(accountID): \(error)")
            }
        }
    }

    // MARK: - Account selection

    /// The single place "which account should this session use" is decided, so a rule
    /// added here applies to launches and to auto-switches alike.
    public func chooseAccount(policyName: String,
                              excluding excluded: Set<String> = []) throws -> AccountRanking {
        guard let policy = store.currentSettings().policy(named: policyName) else {
            throw SessionError.unknownPolicy(policyName)
        }
        guard let choice = PolicyEngine.pick(accounts: store.accounts.all(),
                                             usage: store.allUsage(), policy: policy,
                                             excluding: excluded) else {
            throw SessionError.noEligibleAccount(policy: policyName)
        }
        return choice
    }

    // MARK: - Creation

    public func createSession(policyName: String, cwd: String, pid: Int32,
                             accountID requested: String? = nil) throws -> ControlSessionInfo {
        createLock.lock()
        defer { createLock.unlock() }

        let accountID = try requested ?? chooseAccount(policyName: policyName).accountID
        guard let account = store.accounts.get(accountID) else {
            throw SessionError.unknownAccount(accountID)
        }
        guard vault.credential(for: accountID) != nil else {
            throw SessionError.noCredential(accountID)
        }

        let sessionID = UUID().uuidString.lowercased()
        let namespace = Paths.namespace(sessionID)
        try FileManager.default.createDirectory(at: namespace,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        var record = SessionRecord(id: sessionID, pid: pid, port: 0, accountID: accountID,
                                   policyName: policyName, cwd: cwd)

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
        store.sessions.upsert(record)
        Log.info("session \(sessionID) pid=\(pid) account=\(account.displayName) "
                 + "policy=\(policyName) port=\(record.port)")

        return ControlSessionInfo(sessionID: sessionID, namespaceDir: namespace.path,
                                  port: record.port, accountID: accountID,
                                  accountLabel: account.displayName,
                                  policyName: policyName, pid: pid)
    }

    private func makeProxy(sessionID: String, desiredPort: UInt16?) -> SessionProxy {
        SessionProxy(
            sessionID: sessionID,
            desiredPort: desiredPort,
            router: self,
            observer: { [weak self] observation in
                self?.onObservation?(observation, sessionID)
            })
    }

    // MARK: - SessionRouting

    public func assignment(sessionID: String) -> (accountID: String, token: String)? {
        guard let current = store.sessions.get(sessionID),
              let token = vault.bearerToken(for: current.accountID) else { return nil }
        return (current.accountID, token)
    }

    /// Another account that can serve this model right now, preferring the one with the
    /// most headroom on the windows that actually gate it. Reassigns the session, so the
    /// rest of it continues on the account that worked.
    public func failover(sessionID: String, model: String?,
                         tried: Set<String>) -> (accountID: String, token: String)? {
        let usage = store.allUsage()
        let candidate = store.accounts.all()
            .filter { !tried.contains($0.id) && $0.health != .needsRelogin }
            .filter { ModelRouting.canServe(model, usage: usage[$0.id]) }
            .max { lhs, rhs in
                let l = ModelRouting.headroom(for: model, in: usage[lhs.id]) ?? 100
                let r = ModelRouting.headroom(for: model, in: usage[rhs.id]) ?? 100
                if l != r { return l < r }
                return lhs.priority > rhs.priority
            }
        guard let candidate, let token = vault.bearerToken(for: candidate.id) else {
            return nil
        }
        if store.sessions.get(sessionID)?.accountID != candidate.id {
            try? assign(sessionID: sessionID, accountID: candidate.id)
        }
        return (candidate.id, token)
    }

    /// The soonest any account could serve this model — the number Claude Code needs to
    /// decide whether waiting is worth it.
    public func soonestAvailability(model: String?) -> Date? {
        ModelRouting.soonestAvailable(model, accounts: store.accounts.all(),
                                      usage: store.allUsage())?.at
    }

    /// Writes the account's credential where Claude Code will look for it, in the form
    /// it cannot refresh — see `OAuthCredential.neuteredForSession`.
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
        try ClaudeCredentialStore.write(credential.neuteredForSession(), namespace: namespace)
    }

    // MARK: - Reassignment

    /// Points a session at a different account. The proxy reads the assignment per
    /// request, so this takes effect on the session's very next call.
    public func assign(sessionID: String, accountID: String) throws {
        guard store.accounts.get(accountID) != nil else {
            throw SessionError.unknownAccount(accountID)
        }
        guard vault.credential(for: accountID) != nil else {
            throw SessionError.noCredential(accountID)
        }
        guard let existing = store.sessions.get(sessionID) else {
            throw SessionError.unknownSession(sessionID)
        }
        guard existing.accountID != accountID else { return }

        store.sessions.mutate(sessionID) { $0.accountID = accountID }
        // Re-seed so a restart of this session boots on the new account too. A failure
        // here is not fatal — the proxy already serves the new account — but it must
        // not be silent.
        do {
            try seed(accountID: accountID, into: Paths.namespace(sessionID))
        } catch {
            Log.warn("session \(sessionID) moved to \(accountID) but its namespace could "
                     + "not be re-seeded: \(error)")
        }
        Log.info("session \(sessionID) reassigned to account \(accountID)")
    }

    /// Moves a session off an account that just hit a limit. Returns what happened so
    /// the caller can phrase it; the decision itself stays here with `chooseAccount`.
    public func reassignAfterExhaustion(sessionID: String,
                                        globallyEnabled: Bool) -> ReassignOutcome {
        guard let record = store.sessions.get(sessionID) else {
            return .failed(SessionError.unknownSession(sessionID).localizedDescription)
        }
        guard record.autoSwitchEnabled(default: globallyEnabled) else { return .disabled }

        // Prefer an account with headroom on every window it reports, then fall back to
        // the launch policy. The two differ when the session has switched models
        // in-flight: `cc-opus` deliberately ignores the per-model weekly window, so the
        // window that actually ran out may be one its own policy does not look at.
        let accounts = store.accounts.all()
        let usage = store.allUsage()
        let excluded: Set<String> = [record.accountID]
        let replacement = PolicyEngine.pick(accounts: accounts, usage: usage,
                                            policy: PolicyEngine.everyWindow,
                                            excluding: excluded)
            ?? (try? chooseAccount(policyName: record.policyName, excluding: excluded))
        guard let replacement else { return .noneEligible }
        do {
            try assign(sessionID: sessionID, accountID: replacement.accountID)
            return .switched(from: record.accountID, to: replacement.accountID)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Teardown

    public func endSession(_ sessionID: String) {
        lock.lock()
        let proxy = proxies.removeValue(forKey: sessionID)
        lock.unlock()
        proxy?.stop()

        if let record = store.sessions.get(sessionID) {
            // Nothing to salvage: the seeded credential carries no refresh token, so
            // Claude Code cannot have rotated anything in here.
            try? ClaudeCredentialStore.clear(namespace: record.namespaceDir)
            try? FileManager.default.removeItem(at: record.namespaceDir)
        }
        store.sessions.remove(sessionID)
        Log.info("session \(sessionID) ended")
    }

    /// Ends sessions whose claude process is gone.
    public func reap() {
        for record in store.sessions.all() where !ClaudeSessions.isAlive(record.pid) {
            endSession(record.id)
        }
    }

    /// Everything that has to happen once at launch, in the order it has to happen:
    /// drop dead records, rebind the survivors' ports, then delete namespaces no record
    /// claims. One entry point so a second caller cannot get the order wrong.
    public func recoverAfterLaunch() {
        reap()
        restoreProxies()
        sweepOrphanNamespaces()
    }

    /// Removes namespace directories with no matching session record, which is what a
    /// crash leaves behind.
    private func sweepOrphanNamespaces() {
        let live = Set(store.sessions.all().map(\.id))
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
    /// re-binding the same port. A session whose port is gone cannot be rescued and is
    /// ended, which is at least an honest failure.
    private func restoreProxies() {
        for record in store.sessions.all() {
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
