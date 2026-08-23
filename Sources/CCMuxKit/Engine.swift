import AppKit
import Foundation
import SwiftUI

/// Orchestrates accounts, usage and notifications, and is the observable object every
/// screen reads from. Session mechanics live in `SessionManager`, account selection in
/// `PolicyEngine`, and the control socket in `ControlHandler` — this is the UI-facing
/// layer plus the policies that decide when to warn and when to move a session.
@MainActor
public final class Engine: ObservableObject {
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var usage: [String: UsageSnapshot] = [:]
    @Published public private(set) var sessions: [SessionRecord] = []
    @Published public private(set) var claudeSessions: [ClaudeSessionInfo] = []
    @Published public private(set) var chromeProfiles: [ChromeProfile] = []
    @Published public private(set) var settings: Settings
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

    private let store = Store()
    private let vault = TokenVault()
    private let notifier = Notifier()
    private let client = OAuthClient()
    private lazy var sessionManager = SessionManager(store: store, vault: vault)
    private var controlHandler: ControlHandler?
    private var controlServer: ControlServer?
    private var timers: [Timer] = []
    private var chromeStateStamp: Date?
    private var lastForcedPoll = Date.distantPast
    private var lastProbe: [String: Date] = [:]
    /// Sessions waiting for a turn boundary before their account changes, and when the
    /// wait began.
    private var pendingSwitch: [String: (accountID: String, since: Date)] = [:]
    /// A session retrying against a refusal can report `busy` indefinitely, so the wait
    /// for a turn boundary is capped rather than unbounded.
    private static let turnBoundaryGrace: TimeInterval = 120

    public var accountsNeedingAttention: [Account] {
        accounts.filter { $0.health == .needsRelogin }
    }

    /// What the burger badge surfaces.
    public var needsAttention: Bool { !accountsNeedingAttention.isEmpty }

    public init() {
        settings = store.currentSettings()
    }

    // MARK: - Lifecycle

    public func start() {
        vault.onRefreshFailure = { [weak self] accountID, error in
            Task { @MainActor in self?.handleRefreshFailure(accountID, error) }
        }
        vault.onPersistFailure = { [weak self] accountID, error in
            Task { @MainActor in self?.handlePersistFailure(accountID, error) }
        }
        vault.onCredentialChanged = { [weak self] accountID, _ in
            Task { @MainActor in self?.markHealthy(accountID) }
        }
        sessionManager.onObservation = { [weak self] observation, sessionID in
            Task { @MainActor in self?.handle(observation, sessionID: sessionID) }
        }
        store.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }

        // Loaded before the control socket accepts anything: a shim arriving during a
        // cold launch would otherwise be told the account has no stored credential.
        // Each read spawns `security` (~11ms), so a handful of accounts is not worth
        // deferring.
        vault.load(accountIDs: store.accounts.all().map(\.id))

        sessionManager.recoverAfterLaunch()
        reload(rescanClaudeSessions: true)
        refreshChromeProfiles()
        Task { await checkNotificationAuthorization() }
        startControlServer()
        scheduleTimers()
        Task {
            await refreshExpiringTokens()
            // Not `force`: that stamps the manual-refresh floor and would make the
            // Refresh button a silent no-op for the first minute after launch.
            await pollDueAccounts()
        }
    }

    public func stop() {
        for timer in timers { timer.invalidate() }
        timers = []
        controlServer?.stop()
        sessionManager.stopAll()
    }

    private func startControlServer() {
        let handler = ControlHandler(store: store, sessions: sessionManager)
        handler.importGlobalLogin = { [weak self] in
            guard let self else { return "ccmux is shutting down" }
            return await self.importGlobalLogin()
        }
        controlHandler = handler
        let server = ControlServer { [weak handler] request in
            handler?.handle(request) ?? .failure("ccmux is shutting down")
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
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sessionManager.reap()
                self?.reload(rescanClaudeSessions: true)
                self?.applyPendingSwitches()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Tokens first: polling with one that is about to expire spends a request
                // from the endpoint's hourly budget on a guaranteed 401.
                await self?.refreshExpiringTokens()
                await self?.pollDueAccounts()
                await self?.keepWindowsRolling()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshChromeProfiles() }
        })
    }

    /// Republishes only what changed: `@Published` fires on every assignment, so
    /// assigning unconditionally on a 5-second timer would re-render the whole window
    /// forever.
    private func reload(rescanClaudeSessions: Bool = false) {
        let freshAccounts = store.accounts.all().sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
        if accounts != freshAccounts { accounts = freshAccounts }

        let freshUsage = store.allUsage()
        if usage != freshUsage { usage = freshUsage }

        let freshSessions = store.sessions.all().sorted { $0.startedAt > $1.startedAt }
        if sessions != freshSessions { sessions = freshSessions }

        // Only on the timer: this scans ~/.claude/sessions and reads a file per live
        // session, and store changes fire once per proxied response.
        if rescanClaudeSessions {
            let fresh = ClaudeSessions.list()
            if claudeSessions != fresh { claudeSessions = fresh }
        }

        let freshSettings = store.currentSettings()
        if settings != freshSettings { settings = freshSettings }
    }

    /// Chrome's `Local State` changes when a profile is added, which is close to never,
    /// so it is only re-read when the file's timestamp moves.
    private func refreshChromeProfiles() {
        let stamp = try? FileManager.default
            .attributesOfItem(atPath: ChromeProfileReader.localStateURL.path)[.modificationDate]
            as? Date
        let resolved = stamp ?? nil
        guard resolved != chromeStateStamp || chromeProfiles.isEmpty else { return }
        chromeStateStamp = resolved
        chromeProfiles = ChromeProfileReader.load()
    }

    // MARK: - Usage

    private func pollDueAccounts(force: Bool = false) async {
        let now = Date()
        if force {
            // The Refresh button must not be a way to burn the endpoint's hourly budget.
            guard now.timeIntervalSince(lastForcedPoll) >= PollPolicy.forcedPollFloor else {
                return
            }
            lastForcedPoll = now
        }
        let due = store.accounts.all().filter { account in
            guard account.health != .needsRelogin else { return false }
            if force { return true }
            guard let next = store.usage(for: account.id)?.nextPollAt else { return true }
            return next <= now
        }
        guard !due.isEmpty else { return }

        // One round trip each, overlapped: five accounts should fill in together rather
        // than over five serialized timeouts.
        let fetched = await withTaskGroup(of: (String, Result<[UsageWindow], Error>)?.self) {
            group -> [String: Result<[UsageWindow], Error>] in
            for account in due {
                guard let token = vault.credential(for: account.id)?.accessToken else { continue }
                group.addTask { [client] in
                    do {
                        return (account.id, .success(try await client.usage(accessToken: token)))
                    } catch {
                        return (account.id, .failure(error))
                    }
                }
            }
            var results: [String: Result<[UsageWindow], Error>] = [:]
            for await item in group {
                if let item { results[item.0] = item.1 }
            }
            return results
        }

        for (accountID, result) in fetched { record(result, for: accountID) }
    }

    /// Fetches one account's usage now, bypassing the manual-refresh floor. Used when an
    /// account has just been added and has nothing to show yet.
    private func poll(_ accountID: String) async {
        guard let token = vault.credential(for: accountID)?.accessToken else { return }
        do {
            record(.success(try await client.usage(accessToken: token)), for: accountID)
        } catch {
            record(.failure(error), for: accountID)
        }
    }

    private func record(_ result: Result<[UsageWindow], Error>, for accountID: String) {
        let previous = store.usage(for: accountID)
        var snapshot: UsageSnapshot
        var rateLimited = false

        switch result {
        case .success(let windows):
            snapshot = UsageSnapshot(windows: windows, fetchedAt: Date(),
                                     lastEndpointFetchAt: Date())
            markHealthy(accountID)
        case .failure(let error):
            snapshot = UsageSnapshot(windows: previous?.windows ?? [],
                                     fetchedAt: previous?.fetchedAt ?? .distantPast,
                                     lastEndpointFetchAt: previous?.lastEndpointFetchAt,
                                     lastError: error.localizedDescription)
            if let oauth = error as? OAuthError {
                rateLimited = oauth.statusCode == 429
                if oauth.isPermanent { handleRefreshFailure(accountID, oauth) }
            }
        }

        let plan = PollPolicy.plan(isInUse: store.isInUse(accountID), previous: previous,
                                   current: snapshot,
                                   threshold: settings.warnThresholdPercent,
                                   rateLimited: rateLimited)
        snapshot.nextPollAt = plan.nextPollAt
        store.setUsage(snapshot, for: accountID)
        evaluateThresholds(for: accountID, snapshot: snapshot)
    }

    /// Starts the 5-hour window on accounts whose clock is stopped, so it is already
    /// running by the time you sit down. One minimal Haiku call per account per cycle.
    private func keepWindowsRolling() async {
        guard settings.keepWindowsRolling else { return }
        for account in store.accounts.all() {
            guard WindowProbe.shouldProbe(account: account,
                                          usage: store.usage(for: account.id),
                                          lastProbe: lastProbe[account.id]) else { continue }
            // Non-blocking: a token that needs refreshing is skipped without stamping,
            // so the probe is not deferred 30 minutes over a refresh that was in flight.
            guard let token = vault.cachedBearerToken(for: account.id) else { continue }
            lastProbe[account.id] = Date()
            do {
                try await client.startUsageWindow(accessToken: token)
                Log.info("started the 5-hour window on \(displayName(account.id))")
                await poll(account.id)
            } catch {
                Log.warn("could not start the 5-hour window on "
                         + "\(displayName(account.id)): \(error.localizedDescription)")
            }
        }
    }

    public func refreshNow() {
        Task { await pollDueAccounts(force: true) }
    }

    private func refreshExpiringTokens() async {
        await vault.refreshExpiring(accountIDs: store.accounts.all()
            .filter { $0.health != .needsRelogin }
            .map(\.id))
    }

    /// Merges the rate-limit headers that ride along on every proxied response. Free
    /// and exact for the 5-hour and weekly windows; per-model windows never appear
    /// there, so whatever the usage endpoint last reported is kept.
    private func handle(_ observation: SessionProxy.Observation, sessionID: String) {
        let fromHeaders = UsageParser.windowsFromResponseHeaders(observation.headers)
        if !fromHeaders.isEmpty {
            var snapshot = store.usage(for: observation.accountID) ?? UsageSnapshot()
            for window in fromHeaders { snapshot.windows.upsert(window) }
            snapshot.fetchedAt = Date()
            snapshot.lastError = nil
            store.setUsage(snapshot, for: observation.accountID)
            evaluateThresholds(for: observation.accountID, snapshot: snapshot)
        }

        guard UsageParser.isRateLimited(headers: observation.headers,
                                        statusCode: observation.statusCode) else { return }
        // The response may belong to a request that was already on the wire when the
        // account changed. Its usage still counts against the account that served it,
        // but moving the session on it would undo a choice just made.
        guard store.sessions.get(sessionID)?.accountID == observation.accountID else {
            Log.info("ignoring a rate-limit response for \(observation.accountID); "
                     + "session \(sessionID) has already moved on")
            return
        }
        handleExhaustion(sessionID: sessionID, accountID: observation.accountID)
    }

    // MARK: - Thresholds and exhaustion

    private func evaluateThresholds(for accountID: String, snapshot: UsageSnapshot) {
        guard !settings.mutedAccountIDs.contains(accountID),
              let account = store.accounts.get(accountID),
              store.isInUse(accountID) else { return }

        for window in snapshot.windows where settings.watchedWindows.contains(window.kind) {
            guard window.headroom <= settings.warnThresholdPercent else { continue }
            // The reset time is part of the key, so the next period is a new key and
            // re-arms on its own; nothing has to be cleared for that to work.
            let stamp = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            let resetText = window.resetsAt.map { " · resets \(Format.clock($0))" } ?? ""
            notifier.postOnce(
                key: "\(accountID)/\(window.id)/\(stamp)",
                title: "\(account.displayName): \(window.label) almost gone",
                body: String(format: "%.0f%% left%@", window.headroom, resetText))
        }
    }

    private func handleExhaustion(sessionID: String, accountID: String) {
        guard let record = store.sessions.get(sessionID) else { return }
        let accountName = displayName(accountID)

        // At a turn boundary the switch waits for Claude Code to stop working, so the
        // prompt cache is dropped between turns rather than mid-answer.
        if settings.autoSwitch == .atTurnBoundary, isBusy(pid: record.pid) {
            if pendingSwitch[sessionID] == nil {
                pendingSwitch[sessionID] = (accountID, Date())
                Log.info("session \(sessionID) will move off \(accountID) at its next "
                         + "turn boundary")
            }
            return
        }
        performSwitch(sessionID: sessionID, from: accountID, accountName: accountName)
    }

    private func performSwitch(sessionID: String, from accountID: String,
                               accountName: String) {
        switch sessionManager.reassignAfterExhaustion(sessionID: sessionID,
                                                      globallyEnabled: settings.autoSwitch != .off) {
        case .switched(_, let to):
            if settings.notifyOnAutoSwitch {
                notifier.post(title: "Switched to \(displayName(to))",
                              body: "\(accountName) hit its limit; session "
                                  + "\(sessionID.prefix(8)) moved on its next request.")
            }
        case .disabled:
            notifier.postOnce(key: "exhausted/\(sessionID)/\(accountID)/\(periodStamp(accountID))",
                              title: "\(accountName) is out of headroom",
                              body: "Session \(sessionID.prefix(8)) is blocked. "
                                  + "Pick another account in ccmux.")
        case .noneEligible:
            notifier.postOnce(key: "noheadroom/\(sessionID)/\(accountID)/\(periodStamp(accountID))",
                              title: "No account left with headroom",
                              body: "\(accountName) hit its limit and nothing else "
                                  + "satisfies its policy.")
        case .failed(let reason):
            Log.error("auto-switch failed for session \(sessionID): \(reason)")
            banner = Banner(level: .warning, text: "Could not move session "
                            + "\(sessionID.prefix(8)): \(reason)")
        }
    }

    /// Identifies the current window period, so a blocked session is announced again
    /// after the limit resets rather than once for the session's whole life.
    private func periodStamp(_ accountID: String) -> String {
        let resets = store.usage(for: accountID)?.windows.compactMap(\.resetsAt).min()
        return resets.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
    }

    private func applyPendingSwitches() {
        guard !pendingSwitch.isEmpty else { return }
        for (sessionID, pending) in pendingSwitch {
            guard let record = store.sessions.get(sessionID) else {
                pendingSwitch.removeValue(forKey: sessionID)
                continue
            }
            let waited = Date().timeIntervalSince(pending.since) >= Self.turnBoundaryGrace
            guard !isBusy(pid: record.pid) || waited else { continue }
            pendingSwitch.removeValue(forKey: sessionID)
            performSwitch(sessionID: sessionID, from: pending.accountID,
                          accountName: displayName(pending.accountID))
        }
    }

    private func isBusy(pid: Int32) -> Bool {
        claudeSession(forPID: pid)?.status == "busy"
    }

    private func displayName(_ accountID: String) -> String {
        store.accounts.get(accountID)?.displayName ?? accountID
    }

    private func handleRefreshFailure(_ accountID: String, _ error: OAuthError) {
        guard error.isPermanent else {
            banner = Banner(level: .warning,
                            text: "Could not reach Anthropic for \(displayName(accountID)): "
                                + error.localizedDescription)
            return
        }
        guard store.accounts.get(accountID)?.health != .needsRelogin else { return }
        store.accounts.mutate(accountID) {
            $0.health = .needsRelogin
            $0.healthDetail = error.localizedDescription
        }
        let name = displayName(accountID)
        banner = Banner(level: .warning, text: "\(name) needs to be signed in again.")
        if settings.notifyOnReloginNeeded {
            notifier.post(title: "\(name) needs re-login",
                          body: "Its refresh token was rejected. Open ccmux › Accounts "
                              + "and sign in again.")
        }
    }

    /// A rotation that is live on Anthropic's side but only in memory here: a restart
    /// would come back holding a dead refresh token, so say so while it can still be
    /// acted on.
    private func handlePersistFailure(_ accountID: String, _ error: Error) {
        banner = Banner(level: .warning,
                        text: "Could not save \(displayName(accountID))'s refreshed "
                            + "credential (\(error.localizedDescription)). Quitting ccmux "
                            + "now would require signing that account in again.")
    }

    private func markHealthy(_ accountID: String) {
        guard let account = store.accounts.get(accountID), account.health != .ok else { return }
        store.accounts.mutate(accountID) {
            $0.health = .ok
            $0.healthDetail = nil
        }
    }

    private func checkNotificationAuthorization() async {
        guard await notifier.requestAuthorizationIfNeeded() == .denied else { return }
        if banner == nil {
            banner = Banner(level: .warning,
                            text: "Notifications are turned off for ccmux, so limit "
                                + "warnings cannot reach you.",
                            action: .openNotificationSettings)
        }
    }

    /// Opens the pane where a denied notification permission can be turned back on.
    public func openNotificationSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.notifications"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Accounts

    /// Adds the credential Claude Code is already logged in with. Returns nil on
    /// success, or a message — the control socket needs a verdict, and reading it back
    /// out of `banner` would report unrelated warnings as import failures.
    @discardableResult
    public func importGlobalLogin() async -> String? {
        guard let credential = (try? ClaudeCredentialStore.readGlobal()) ?? nil else {
            let message = "Claude Code is not logged in on this Mac."
            banner = Banner(level: .warning, text: message)
            return message
        }
        do {
            let account = try await adopt(credential: credential,
                                          chromeProfileDirectory: nil, label: nil)
            banner = Banner(level: .info, text: "Signed in as \(account.displayName).")
            return nil
        } catch {
            let message = "Signed in, but could not read the account: "
                + error.localizedDescription
            banner = Banner(level: .warning, text: message)
            return message
        }
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
            let items = try await listener.awaitCallback(timeout: 300)
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
            let account = try await adopt(credential: credential,
                                          chromeProfileDirectory: chromeProfileDirectory,
                                          label: label)
            banner = Banner(level: .info, text: "Signed in as \(account.displayName).")
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    /// Signs an account in again, reusing everything already known about it — including
    /// its Chrome profile, which is the whole point of that setting.
    public func relogin(accountID: String) {
        guard let account = store.accounts.get(accountID) else { return }
        Task {
            await beginLogin(chromeProfileDirectory: account.chromeProfileDirectory,
                             label: account.label, loginHint: account.email)
        }
    }

    private func adopt(credential: OAuthCredential, chromeProfileDirectory: String?,
                       label: String?) async throws -> Account {
        let identity = try await client.profile(accessToken: credential.accessToken)
        var account = store.accounts.get(identity.uuid)
            ?? Account(id: identity.uuid, label: label ?? identity.email ?? identity.uuid)
        if let label, !label.isEmpty { account.label = label }
        account.email = identity.email ?? account.email
        account.organizationUUID = identity.organizationUUID
        account.organizationName = identity.organizationName ?? account.organizationName
        account.subscriptionType = credential.subscriptionType ?? account.subscriptionType
        account.rateLimitTier = credential.rateLimitTier ?? account.rateLimitTier
        if let chromeProfileDirectory { account.chromeProfileDirectory = chromeProfileDirectory }
        account.health = .ok
        account.healthDetail = nil
        if account.priority == 0 {
            account.priority = (store.accounts.all().map(\.priority).max() ?? 0) + 1
        }
        store.accounts.upsert(account)
        vault.store(credential, for: account.id)
        await poll(account.id)
        return account
    }

    public func removeAccount(_ accountID: String) {
        for record in store.sessions(forAccount: accountID) {
            sessionManager.endSession(record.id)
        }
        vault.forget(accountID)
        store.removeAccount(accountID)
    }

    public func setLabel(_ label: String, for accountID: String) {
        store.accounts.mutate(accountID) { $0.label = label }
    }

    public func setChromeProfile(_ directory: String?, for accountID: String) {
        store.accounts.mutate(accountID) { $0.chromeProfileDirectory = directory }
    }

    public func movePriority(_ accountID: String, by delta: Int) {
        var ordered = accounts
        guard let index = ordered.firstIndex(where: { $0.id == accountID }) else { return }
        let target = index + delta
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (rank, account) in ordered.enumerated() {
            store.accounts.mutate(account.id) { $0.priority = rank }
        }
    }

    public func chromeProfile(for account: Account) -> ChromeProfile? {
        guard let directory = account.chromeProfileDirectory else { return nil }
        return chromeProfiles.first { $0.directory == directory }
    }

    public func sessionCount(forAccount accountID: String) -> Int {
        sessions.reduce(0) { $0 + ($1.accountID == accountID ? 1 : 0) }
    }

    // MARK: - Sessions

    public func assign(sessionID: String, to accountID: String) {
        do {
            try sessionManager.assign(sessionID: sessionID, accountID: accountID)
            pendingSwitch.removeValue(forKey: sessionID)
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    public func setAutoSwitch(_ enabled: Bool, for sessionID: String) {
        store.sessions.mutate(sessionID) { $0.autoSwitchOverride = enabled }
    }

    public func endSession(_ sessionID: String) {
        sessionManager.endSession(sessionID)
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
}
