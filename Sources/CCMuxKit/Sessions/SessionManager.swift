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
    public func chooseAccount(policyName: String, excluding excluded: Set<String> = [],
                              applyingLaunchFloors: Bool = false)
        throws -> (choice: AccountRanking, warning: String?) {
        guard let policy = store.currentSettings().policy(named: policyName) else {
            throw SessionError.unknownPolicy(policyName)
        }
        let accounts = store.accounts.all()
        let usage = store.allUsage()
        if applyingLaunchFloors,
           let clears = PolicyEngine.pick(accounts: accounts, usage: usage, policy: policy,
                                          excluding: excluded, applyingLaunchFloors: true) {
            return (clears, nil)
        }
        // Nothing clears the floor. Starting on scraps beats not starting: the floors
        // exist to pick a good account, not to refuse work when quota is tight.
        guard let fallback = PolicyEngine.rank(accounts: accounts, usage: usage,
                                               policy: policy, excluding: excluded).last else {
            throw SessionError.noEligibleAccount(policy: policyName)
        }
        let warning = applyingLaunchFloors
            ? String(format: "no account clears the %@ floor; best has %.0f%% left on %@",
                     policyName, fallback.headroom, fallback.bindingWindow ?? "its limits")
            : nil
        return (fallback, warning)
    }

    // MARK: - Creation

    public func createSession(policyName: String, cwd: String, pid: Int32,
                             accountID requested: String? = nil) throws -> ControlSessionInfo {
        createLock.lock()
        defer { createLock.unlock() }

        var warning: String?
        let accountID: String
        if let requested {
            accountID = requested
        } else {
            let chosen = try chooseAccount(policyName: policyName, applyingLaunchFloors: true)
            accountID = chosen.choice.accountID
            warning = chosen.warning
        }
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
                                  policyName: policyName, pid: pid, warning: warning)
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

    /// Where to retry a request that `servedBy` refused, least remaining first, so a
    /// subscription is drained before the next one is started on.
    ///
    /// Eligibility is model-aware and is the part that must not be relaxed: a Fable
    /// request only considers accounts with Fable weekly headroom, never one that merely
    /// has general weekly left.
    public func failover(sessionID: String, model: String?, servedBy: String,
                         tried: Set<String>) -> (accountID: String, token: String)? {
        guard let record = store.sessions.get(sessionID) else { return nil }

        // The account changed while this request was in flight — the user picked another
        // one, or an earlier refusal already moved it. Honour that rather than ranking
        // again, which could drag the session to a third account nobody chose.
        if record.accountID != servedBy, !tried.contains(record.accountID) {
            let usage = store.allUsage()
            if ModelRouting.canServe(model, usage: usage[record.accountID]),
               let token = vault.cachedBearerToken(for: record.accountID) {
                return (record.accountID, token)
            }
        }

        // Moving a session between subscriptions is exactly what auto-switch governs, so
        // an explicit "off" has to stop it here too, not only in the exhaustion notice.
        let settings = store.currentSettings()
        guard record.autoSwitchEnabled(default: settings.autoSwitch != .off) else {
            return nil
        }
        // A mid-request retry is mid-turn by definition, which is the one thing this mode
        // exists to avoid. Let the refusal through and let Engine schedule the move for
        // the turn boundary instead.
        guard settings.autoSwitch != .atTurnBoundary else { return nil }

        let usage = store.allUsage()
        let policy = settings.policy(named: record.policyName)
        let candidate = ModelRouting.rankLeastRemaining(model, accounts: store.accounts.all(),
                                                        usage: usage, excluding: tried)
            // Never blocks: a candidate whose token needs refreshing is skipped rather
            // than waited on, and the vault refreshes it in the background.
            .first { vault.cachedBearerToken(for: $0.id) != nil }
        guard let candidate, let token = vault.cachedBearerToken(for: candidate.id) else {
            return nil
        }

        // Claude Code makes auxiliary calls (titles, summaries) on models the session's
        // policy says nothing about. Serving one elsewhere is fine; rehoming the whole
        // session on the strength of it is not — the next real request would be refused
        // and switch again, dropping the prompt cache each time.
        let servesThePolicy = policy.map { p in
            PolicyEngine.headroom(for: candidate, usage: usage[candidate.id],
                                  policy: p) != nil
        } ?? true
        if record.accountID != candidate.id, servesThePolicy {
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
        let settings = store.currentSettings()

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
            ?? PolicyEngine.pick(accounts: accounts, usage: usage,
                                 policy: settings.policy(named: record.policyName)
                                     ?? PolicyEngine.everyWindow,
                                 excluding: excluded)
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
        // A session carried over from a build that seeded a *refreshable* credential
        // would still have one; its Claude Code could rotate the lineage with nothing
        // adopting the result, killing the account's stored refresh token.
        for record in store.sessions.all() {
            guard let credential = vault.credential(for: record.accountID) else { continue }
            let seeded = credential.neuteredForSession()
            if let existing = (try? ClaudeCredentialStore.read(namespace: record.namespaceDir))
                ?? nil, existing.refreshToken == nil,
               existing.accessToken == seeded.accessToken { continue }
            try? ClaudeCredentialStore.write(seeded, namespace: record.namespaceDir)
            Log.info("re-seeded namespace for session \(record.id)")
        }
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
