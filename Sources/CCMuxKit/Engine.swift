import AppKit
import Foundation
import SwiftUI

/// Orchestrates accounts, usage, sessions and notifications, and is the observable
/// object every screen reads from.
@MainActor
public final class Engine: ObservableObject {
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var usage: [String: UsageSnapshot] = [:]
    @Published public private(set) var sessions: [SessionRecord] = []
    @Published public private(set) var claudeSessions: [ClaudeSessionInfo] = []
    @Published public private(set) var chromeProfiles: [ChromeProfile] = []
    @Published public var settings: Settings
    @Published public private(set) var banner: Banner?
    @Published public private(set) var loginInProgress = false

    public struct Banner: Equatable {
        public enum Level { case info, warning }
        public enum Action: Equatable { case openNotificationSettings }
        public var level: Level
        public var text: String
        public var action: Action?

        public init(level: Level, text: String, action: Action? = nil) {
            self.level = level
            self.text = text
            self.action = action
        }
    }

    @Published public private(set) var notificationsBlocked = false

    /// Opens the pane where a denied notification permission can be turned back on.
    public func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    private let store = Store()
    private let vault = TokenVault()
    private let notifier = Notifier()
    private let client = OAuthClient()
    private lazy var sessionManager = SessionManager(store: store, vault: vault)
    private var controlServer: ControlServer?
    private var timers: [Timer] = []

    /// Any condition the burger badge should surface.
    public var needsAttention: Bool {
        accounts.contains { $0.health == .needsRelogin }
    }

    public var accountsNeedingAttention: [Account] {
        accounts.filter { $0.health == .needsRelogin }
    }

    public init() {
        settings = store.currentSettings()
    }

    // MARK: - Lifecycle

    public func start() {
        reload()
        vault.load(accountIDs: accounts.map(\.id))
        vault.lineageOwner = { [weak self] accountID in
            self?.sessionManager.lineageOwner(accountID: accountID)
        }
        vault.onRefreshFailure = { [weak self] accountID, error in
            Task { @MainActor in self?.handleRefreshFailure(accountID, error) }
        }
        vault.onCredentialChanged = { [weak self] accountID, _ in
            Task { @MainActor in self?.markHealthy(accountID) }
        }
        sessionManager.onObservation = { [weak self] observation, sessionID in
            Task { @MainActor in self?.handle(observation, sessionID: sessionID) }
        }

        sessionManager.reap()
        sessionManager.restoreProxies()
        sessionManager.sweepOrphanNamespaces()
        reload()

        chromeProfiles = ChromeProfileReader.load()
        Task { await checkNotificationAuthorization() }
        startControlServer()
        scheduleTimers()
        Task { await pollDueAccounts(force: true) }
    }

    public func stop() {
        for timer in timers { timer.invalidate() }
        timers = []
        controlServer?.stop()
        sessionManager.stopAll()
    }

    private func checkNotificationAuthorization() async {
        let state = await notifier.requestAuthorizationIfNeeded()
        notificationsBlocked = state == .denied
        if notificationsBlocked, banner == nil {
            banner = Banner(level: .warning,
                            text: "Notifications are turned off for ccmux, so limit "
                                + "warnings cannot reach you.",
                            action: .openNotificationSettings)
        }
    }

    private func startControlServer() {
        let server = ControlServer { [weak self] request in
            guard let self else { return .failure("ccmux is shutting down") }
            return self.handleControl(request)
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            Log.error("control socket failed to start: \(error.localizedDescription)")
            banner = Banner(level: .warning,
                            text: "Control socket unavailable: \(error.localizedDescription)")
        }
    }

    private func scheduleTimers() {
        // Session liveness and the session list Claude Code publishes.
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sessionManager.reap()
                self?.reload()
            }
        })
        // Usage polling and token upkeep.
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollDueAccounts()
                await self?.refreshExpiringTokens()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.chromeProfiles = ChromeProfileReader.load() }
        })
    }

    private func reload() {
        accounts = store.allAccounts().sorted {
            ($0.priority, $0.displayName.lowercased()) < ($1.priority, $1.displayName.lowercased())
        }
        usage = store.allUsage()
        sessions = store.allSessions().sorted { $0.startedAt > $1.startedAt }
        claudeSessions = ClaudeSessions.list()
        settings = store.currentSettings()
    }

    // MARK: - Control channel

    private func handleControl(_ request: ControlRequest) -> ControlResponse {
        switch request {
        case .ping:
            return .ok

        case .newSession(let policy, let cwd, let pid):
            do {
                let info = try sessionManager.createSession(policyName: policy, cwd: cwd, pid: pid)
                Task { @MainActor in self.reload() }
                return .session(info)
            } catch {
                return .failure(error.localizedDescription)
            }

        case .endSession(let sessionID):
            sessionManager.endSession(sessionID)
            Task { @MainActor in self.reload() }
            return .ok

        case .assign(let sessionID, let accountID):
            do {
                try sessionManager.assign(sessionID: sessionID, accountID: accountID)
                Task { @MainActor in self.reload() }
                return .ok
            } catch {
                return .failure(error.localizedDescription)
            }

        case .importGlobalLogin:
            guard let credential = (try? ClaudeCredentialStore.readGlobal()) ?? nil else {
                return .failure("Claude Code is not logged in on this Mac")
            }
            let semaphore = DispatchSemaphore(value: 0)
            var failure: String?
            Task { @MainActor in
                await self.adopt(credential: credential, chromeProfileDirectory: nil,
                                 label: nil)
                if case .warning = self.banner?.level { failure = self.banner?.text }
                semaphore.signal()
            }
            // The control channel is synchronous and callers expect a real verdict, so
            // block this connection's thread — never the main actor — until the import
            // settles.
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                return .failure("sign-in did not complete in time")
            }
            if let failure { return .failure(failure) }
            return .ok

        case .status:
            let now = Date()
            let accountInfos = store.allAccounts().map { account in
                let snapshot = store.usage(for: account.id)
                return ControlAccountInfo(
                    id: account.id, label: account.displayName, email: account.email,
                    health: account.health.rawValue, windows: snapshot?.windows ?? [],
                    usageAge: snapshot.map { now.timeIntervalSince($0.fetchedAt) })
            }
            let sessionInfos = store.allSessions().map { record in
                ControlSessionInfo(
                    sessionID: record.id, namespaceDir: record.namespaceDir.path,
                    port: record.port, accountID: record.accountID,
                    accountLabel: store.account(record.accountID)?.displayName ?? record.accountID,
                    policyName: record.policyName, pid: record.pid)
            }
            return .status(ControlStatus(accounts: accountInfos, sessions: sessionInfos))
        }
    }

    // MARK: - Usage

    private func pollDueAccounts(force: Bool = false) async {
        let now = Date()
        for account in store.allAccounts() {
            guard account.health != .needsRelogin else { continue }
            let previous = store.usage(for: account.id)
            if !force, let next = previous?.nextPollAt, next > now { continue }
            if !force, let previous, now.timeIntervalSince(previous.fetchedAt)
                < PollPolicy.serveTTL { continue }
            await poll(account)
        }
    }

    private func poll(_ account: Account) async {
        guard let token = vault.credential(for: account.id)?.accessToken else { return }
        let previous = store.usage(for: account.id)
        let isInUse = store.allSessions().contains { $0.accountID == account.id }
        var snapshot: UsageSnapshot
        var rateLimited = false
        do {
            let windows = try await client.usage(accessToken: token)
            snapshot = UsageSnapshot(windows: windows, fetchedAt: Date())
            markHealthy(account.id)
        } catch let error as OAuthError {
            rateLimited = error.localizedDescription.contains("HTTP 429")
            snapshot = UsageSnapshot(windows: previous?.windows ?? [],
                                     fetchedAt: previous?.fetchedAt ?? .distantPast,
                                     lastError: error.localizedDescription)
            if error.isPermanent { handleRefreshFailure(account.id, error) }
        } catch {
            snapshot = UsageSnapshot(windows: previous?.windows ?? [],
                                     fetchedAt: previous?.fetchedAt ?? .distantPast,
                                     lastError: error.localizedDescription)
        }
        let plan = PollPolicy.plan(isInUse: isInUse, previous: previous, current: snapshot,
                                   threshold: settings.warnThresholdPercent,
                                   rateLimited: rateLimited)
        snapshot.nextPollAt = plan.nextPollAt
        snapshot.pollInterval = plan.interval
        store.setUsage(snapshot, for: account.id)
        reload()
        evaluateThresholds(for: account.id, snapshot: snapshot)
    }

    public func refreshNow() {
        Task { await pollDueAccounts(force: true) }
    }

    private func refreshExpiringTokens() async {
        let ids = store.allAccounts()
            .filter { $0.health != .needsRelogin }
            .map(\.id)
        await vault.refreshExpiring(accountIDs: ids)
    }

    /// Merges the rate-limit headers that ride along on every proxied response. Free
    /// and exact for the 5-hour and weekly windows; per-model windows never appear
    /// there, so whatever the usage endpoint last reported is kept.
    private func handle(_ observation: SessionProxy.Observation, sessionID: String) {
        let fromHeaders = UsageParser.windowsFromResponseHeaders(observation.headers)
        if !fromHeaders.isEmpty {
            var snapshot = store.usage(for: observation.accountID) ?? UsageSnapshot()
            for window in fromHeaders {
                if let index = snapshot.windows.firstIndex(where: { $0.id == window.id }) {
                    snapshot.windows[index] = window
                } else {
                    snapshot.windows.append(window)
                }
            }
            snapshot.fetchedAt = Date()
            snapshot.lastError = nil
            store.setUsage(snapshot, for: observation.accountID)
            reload()
            evaluateThresholds(for: observation.accountID, snapshot: snapshot)
        }

        if UsageParser.isRateLimited(headers: observation.headers,
                                     statusCode: observation.statusCode) {
            handleExhaustion(sessionID: sessionID, accountID: observation.accountID)
        }
    }

    // MARK: - Thresholds and exhaustion

    private func evaluateThresholds(for accountID: String, snapshot: UsageSnapshot) {
        guard !settings.mutedAccountIDs.contains(accountID) else { return }
        guard let account = store.account(accountID) else { return }
        let inUse = store.allSessions().contains { $0.accountID == accountID }
        guard inUse else { return }

        for window in snapshot.windows where settings.watchedWindows.contains(window.kind) {
            let stamp = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            let key = "\(accountID)/\(window.id)/\(stamp)"
            // A window that turned over re-arms: older stamps for it are no longer
            // interesting and would otherwise suppress the next crossing.
            notifier.rearm(keyPrefix: "\(accountID)/\(window.id)/")
            guard window.headroom <= settings.warnThresholdPercent else { continue }
            let resetText = window.resetsAt.map { " · resets \(Format.clock($0))" } ?? ""
            notifier.postOnce(
                key: key,
                title: "\(account.displayName): \(window.label) almost gone",
                body: String(format: "%.0f%% left%@", window.headroom, resetText))
        }
    }

    private func handleExhaustion(sessionID: String, accountID: String) {
        guard let record = store.session(sessionID) else { return }
        let accountName = store.account(accountID)?.displayName ?? accountID
        guard settings.autoSwitch != .off, record.autoSwitch else {
            notifier.postOnce(key: "exhausted/\(sessionID)/\(accountID)",
                              title: "\(accountName) is out of headroom",
                              body: "Session \(shortID(sessionID)) is blocked. "
                                  + "Pick another account in ccmux.")
            return
        }
        guard let policy = settings.policy(named: record.policyName) else { return }
        guard let replacement = PolicyEngine.pick(accounts: store.allAccounts(),
                                                  usage: store.allUsage(), policy: policy,
                                                  excluding: [accountID]) else {
            notifier.postOnce(key: "noheadroom/\(sessionID)/\(accountID)",
                              title: "No account left with headroom",
                              body: "\(accountName) hit its limit and nothing else "
                                  + "satisfies the “\(record.policyName)” policy.")
            return
        }
        do {
            try sessionManager.assign(sessionID: sessionID, accountID: replacement.accountID)
            reload()
            let newName = store.account(replacement.accountID)?.displayName
                ?? replacement.accountID
            if settings.notifyOnAutoSwitch {
                notifier.post(title: "Switched to \(newName)",
                              body: "\(accountName) hit its limit; session "
                                  + "\(shortID(sessionID)) moved on its next request.")
            }
        } catch {
            Log.error("auto-switch failed for session \(sessionID): \(error)")
        }
    }

    private func handleRefreshFailure(_ accountID: String, _ error: OAuthError) {
        guard error.isPermanent else {
            banner = Banner(level: .warning,
                            text: "Could not reach Anthropic for "
                                + "\(store.account(accountID)?.displayName ?? accountID): "
                                + error.localizedDescription)
            return
        }
        guard store.account(accountID)?.health != .needsRelogin else { return }
        store.mutateAccount(accountID) {
            $0.health = .needsRelogin
            $0.healthDetail = error.localizedDescription
        }
        reload()
        let name = store.account(accountID)?.displayName ?? accountID
        banner = Banner(level: .warning, text: "\(name) needs to be signed in again.")
        if settings.notifyOnReloginNeeded {
            notifier.post(title: "\(name) needs re-login",
                          body: "Its refresh token was rejected. Open ccmux › Accounts "
                              + "and sign in again.")
        }
    }

    private func markHealthy(_ accountID: String) {
        guard let account = store.account(accountID), account.health != .ok else { return }
        store.mutateAccount(accountID) {
            $0.health = .ok
            $0.healthDetail = nil
        }
        reload()
    }

    // MARK: - Accounts

    /// Adds the credential Claude Code is already logged in with, so the current login
    /// becomes an account without signing in again.
    public func importGlobalLogin() async {
        guard let credential = (try? ClaudeCredentialStore.readGlobal()) ?? nil else {
            banner = Banner(level: .warning, text: "Claude Code is not logged in on this Mac.")
            return
        }
        await adopt(credential: credential, chromeProfileDirectory: nil, label: nil)
    }

    public func beginLogin(chromeProfileDirectory: String?, label: String?,
                           loginHint: String?) async {
        guard !loginInProgress else { return }
        loginInProgress = true
        defer { loginInProgress = false }

        let pkce = OAuthClient.PKCE()
        let listener: LoopbackListener
        do {
            listener = try LoopbackListener()
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
            return
        }
        defer { listener.stop() }

        let url = OAuthClient.authorizeURL(pkce: pkce, port: listener.port, email: loginHint)
        let outcome = ChromeLauncher.open(url: url.absoluteString,
                                          profileDirectory: chromeProfileDirectory)
        banner = Banner(level: .info, text: "Waiting for sign-in… \(outcome.message)")

        do {
            let items = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try listener.waitForCallback(timeout: 300))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard let code = items["code"] else {
                banner = Banner(level: .warning, text: "The browser returned no code.")
                return
            }
            guard items["state"] == nil || items["state"] == pkce.state else {
                banner = Banner(level: .warning,
                                text: "Sign-in state did not match; nothing was stored.")
                return
            }
            let credential = try await client.exchange(code: code, pkce: pkce,
                                                       port: listener.port)
            await adopt(credential: credential,
                        chromeProfileDirectory: chromeProfileDirectory, label: label)
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    private func adopt(credential: OAuthCredential, chromeProfileDirectory: String?,
                       label: String?) async {
        do {
            let identity = try await client.profile(accessToken: credential.accessToken)
            var account = store.account(identity.uuid)
                ?? Account(id: identity.uuid, label: label ?? identity.email ?? identity.uuid)
            if let label, !label.isEmpty { account.label = label }
            account.email = identity.email ?? account.email
            account.organizationUUID = identity.organizationUUID
            account.organizationName = identity.organizationName ?? account.organizationName
            account.subscriptionType = credential.subscriptionType ?? account.subscriptionType
            account.rateLimitTier = credential.rateLimitTier ?? account.rateLimitTier
            if let chromeProfileDirectory {
                account.chromeProfileDirectory = chromeProfileDirectory
            }
            account.health = .ok
            account.healthDetail = nil
            if account.priority == 0 {
                account.priority = (store.allAccounts().map(\.priority).max() ?? 0) + 1
            }
            store.upsert(account)
            vault.store(credential, for: account.id)
            reload()
            banner = Banner(level: .info, text: "Signed in as \(account.displayName).")
            await poll(account)
        } catch {
            banner = Banner(level: .warning,
                            text: "Signed in, but could not read the account: "
                                + error.localizedDescription)
        }
    }

    public func removeAccount(_ accountID: String) {
        for record in store.allSessions() where record.accountID == accountID {
            sessionManager.endSession(record.id)
        }
        vault.forget(accountID)
        store.removeAccount(accountID)
        reload()
    }

    public func setLabel(_ label: String, for accountID: String) {
        store.mutateAccount(accountID) { $0.label = label }
        reload()
    }

    public func setChromeProfile(_ directory: String?, for accountID: String) {
        store.mutateAccount(accountID) { $0.chromeProfileDirectory = directory }
        reload()
    }

    public func movePriority(_ accountID: String, by delta: Int) {
        var ordered = accounts
        guard let index = ordered.firstIndex(where: { $0.id == accountID }) else { return }
        let target = index + delta
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (rank, account) in ordered.enumerated() {
            store.mutateAccount(account.id) { $0.priority = rank }
        }
        reload()
    }

    public func chromeProfile(for account: Account) -> ChromeProfile? {
        guard let directory = account.chromeProfileDirectory else { return nil }
        return chromeProfiles.first { $0.directory == directory }
    }

    // MARK: - Sessions

    public func assign(sessionID: String, to accountID: String) {
        do {
            try sessionManager.assign(sessionID: sessionID, accountID: accountID)
            reload()
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    public func setAutoSwitch(_ enabled: Bool, for sessionID: String) {
        store.mutateSession(sessionID) { $0.autoSwitch = enabled }
        reload()
    }

    public func endSession(_ sessionID: String) {
        sessionManager.endSession(sessionID)
        reload()
    }

    public func claudeSession(forPID pid: Int32) -> ClaudeSessionInfo? {
        claudeSessions.first { $0.pid == pid }
    }

    /// Live Claude Code sessions ccmux did not launch, so the Sessions screen tells the
    /// whole truth rather than only the part it manages.
    public var unmanagedSessions: [ClaudeSessionInfo] {
        let managed = Set(sessions.map(\.pid))
        return claudeSessions.filter { !managed.contains($0.pid) }
    }

    // MARK: - Settings

    public func updateSettings(_ body: @escaping (inout Settings) -> Void) {
        settings = store.updateSettings(body)
    }

    public func dismissBanner() {
        banner = nil
    }

    private func shortID(_ id: String) -> String { String(id.prefix(8)) }
}
