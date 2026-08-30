import CCMuxCore
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
    @Published public internal(set) var banner: Banner?
    @Published public internal(set) var loginInProgress = false
    /// The sign-in the login modal is showing, if any. Non-nil from the moment the browser
    /// opens until the user dismisses the result.
    @Published public internal(set) var loginAttempt: LoginAttempt?
    /// What connecting to a ccmuxd would mean for the accounts already on this Mac.
    /// Non-nil only while the connect sheet is deciding.
    @Published public internal(set) var delegationPlan: Delegation.Plan?
    @Published public internal(set) var serverBusy = false
    /// Sessions running on other Macs. In memory only — they are another machine's truth,
    /// and a copy of it restored from disk at launch would be a list of sessions that may
    /// well have ended hours ago.
    @Published public internal(set) var foreignSessions: [ForeignSession] = []
    /// Nil until the server has been asked. False for a ccmuxd built before session
    /// sharing existed, whose routes for it answer 404 — a fact about the server rather
    /// than a failure worth showing as one.
    @Published public internal(set) var serverSupportsSessions: Bool?

    public struct Banner: Equatable {
        public enum Level { case info, warning }
        public enum Action: Equatable {
            case openNotificationSettings
            case openAutomationSettings
        }
        /// What raised it, for banners that should retract themselves once the condition
        /// clears. nil stands until the user dismisses it.
        public enum Source: Equatable { case blockedSession(String) }
        public var level: Level
        public var text: String
        public var action: Action?
        public var source: Source?

        public init(level: Level, text: String, action: Action? = nil,
                    source: Source? = nil) {
            self.level = level
            self.text = text
            self.action = action
            self.source = source
        }
    }

    let store = Store()
    let vault = TokenVault(client: OAuthClient(),
                                   secrets: KeychainSecretStore(
                                       service: AccountCredentialStore.service))
    private let notifier = Notifier()
    var client = OAuthClient()
    lazy var sessionManager = SessionManager(store: store, vault: vault)
    /// Held rather than rebuilt per call: a URLSession with a delegate retains it until
    /// invalidated, so handing out a new client on every access leaked a session and a
    /// pinning delegate each time. Rebuilt only when the connection settings change.
    var serverClientCache: (connection: ServerConnection, client: ServerClient)?
    /// This Mac's name on the server. Loaded once: minting a new id per launch would leave
    /// the server holding a ghost machine for every restart.
    ///
    /// Published because Settings shows and edits it — a plain property leaves the field
    /// and its Save button showing the name from before the rename.
    @Published public internal(set) var machineIdentity = MachineIdentityStore.load()
    /// The last answer from the server, and when it arrived. Kept raw so staleness can go
    /// on advancing while the server is unreachable — a frozen age would show a sleeping
    /// laptop's sessions as current indefinitely.
    ///
    /// Published in its own right rather than left to `foreignSessions`: the Settings list
    /// of machines derives from this alone, and a machine quiet for longer than `hideAfter`
    /// contributes no sessions at all — so nothing would ever republish, and Forget would
    /// appear to do nothing on precisely the machine it exists for.
    @Published var foreignSnapshots: (machines: [MachineSnapshot], fetchedAt: Date)?
    var apiKeyFingerprints = APIKeyFingerprintCache()
    /// One session report in flight at a time.
    var syncingSessions = false
    /// Everything needed to redeem a code, retry the browser, or abandon the attempt.
    var loginContext: LoginContext?
    var loginListener: LoopbackListener?
    var loginTask: Task<Void, Never>?
    /// Guards against two redemptions of one authorize request — a pasted code and the
    /// browser's callback can arrive together.
    var redeemingLogin = false
    /// Identifies the attempt currently on screen. Every login mutation checks it, so a
    /// redeem the user walked away from cannot write its result over its successor.
    var loginGeneration: UUID?
    /// Whether the last session sync failed, so an outage is logged once rather than on
    /// every tick. ccmux.log is where a credential going wrong is diagnosed; three lines a
    /// minute of "could not reach the server" would bury exactly that.
    var sessionSyncFailing = false
    private var controlHandler: ControlHandler?
    private var controlServer: ControlServer?
    private var timers: [Timer] = []
    private var chromeStateStamp: Date?
    private var lastForcedPoll = Date.distantPast
    private var lastProbe: [String: Date] = [:]
    /// Sessions waiting for a turn boundary before their account changes, and when the
    /// wait began.
    private var pendingSwitch: [String: (accountID: String, since: Date,
                                        model: String?)] = [:]
    /// A session retrying against a refusal can report `busy` indefinitely, so the wait
    /// for a turn boundary is capped rather than unbounded.
    private static let turnBoundaryGrace: TimeInterval = 120

    public var accountsNeedingAttention: [Account] {
        accounts.filter { $0.health == .needsRelogin }
    }

    /// Sessions that cannot make progress. Visible in the window rather than only as an
    /// OS notification, which is silently dropped whenever notification permission is
    /// off — the case this exists to survive.
    @Published public private(set) var blocks = BlockLedger()
    /// Sessions with no listener on their port: their claude process is alive and
    /// pointed at a port something else took during a restart. Retried every tick.
    @Published public private(set) var unreachableSessions: Set<String> = []
    /// Models seen on an API key that have no listed price, so the UI can admit the
    /// spend figure is incomplete instead of implying it is exact.
    @Published public private(set) var unpricedModels: Set<String> = []

    /// What the burger badge surfaces.
    public var needsAttention: Bool {
        !accountsNeedingAttention.isEmpty || !blocks.isEmpty
            || !unreachableSessions.isEmpty
    }

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

        repairAccountKinds()
        applyUpstreamProxy()
        applyRemoteToVault()
        sessionManager.recoverAfterLaunch()
        restoreBlocks()
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
            await pollDelegatedUsage()
            await syncSessions()
        }
    }

    public func stop() {
        for timer in timers { timer.invalidate() }
        timers = []
        controlServer?.stop()
        sessionManager.stopAll()
    }

    /// Stops taking new work while letting the requests already in flight finish, so a
    /// restart does not sever a response mid-body. `activeRequests` reports when it is
    /// safe to exit.
    public func beginShutdown() {
        for timer in timers { timer.invalidate() }
        timers = []
        controlServer?.stop()
        sessionManager.quiesceAll()
    }

    public var activeRequests: Int { sessionManager.activeRequestCount() }

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
                self?.sessionManager.retryUnreachable()
                self?.reload(rescanClaudeSessions: true)
                self?.applyPendingSwitches()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Tokens first: polling with one that is about to expire spends a request
                // from the endpoint's hourly budget on a guaranteed 401.
                await self?.refreshExpiringTokens()
                await self?.backfillMissingPlans()
                await self?.pollDueAccounts()
                await self?.pollDelegatedUsage()
                await self?.keepWindowsRolling()
                await self?.syncSessions()
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

        // A reaped session must not leave the badge lit for something that is gone.
        for sessionID in blocks.prune(liveSessionIDs: Set(freshSessions.map(\.id))) {
            retractBanner(owner: sessionID)
        }

        // Only on the timer: this scans ~/.claude/sessions and reads a file per live
        // session, and store changes fire once per proxied response.
        if rescanClaudeSessions {
            let fresh = ClaudeSessions.list()
            if claudeSessions != fresh { claudeSessions = fresh }
        }

        let freshSettings = store.currentSettings()
        if settings != freshSettings { settings = freshSettings }

        let parked = sessionManager.unreachableSessionIDs()
        if unreachableSessions != parked { unreachableSessions = parked }
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
            // An API key has no subscription usage endpoint to poll; its ceilings arrive
            // on response headers and its spend is accumulated per request.
            guard account.kind == .subscription else { return false }
            guard account.health != .needsRelogin else { return false }
            // Delegated accounts are polled once, centrally; see pollDelegatedUsage.
            guard !settings.delegated.contains(account.id) else { return false }
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
    func poll(_ accountID: String) async {
        guard let token = vault.credential(for: accountID)?.accessToken else { return }
        do {
            record(.success(try await client.usage(accessToken: token)), for: accountID)
        } catch {
            record(.failure(error), for: accountID)
        }
    }

    func record(_ result: Result<[UsageWindow], Error>, for accountID: String,
                fetchedAt: Date = Date()) {
        let previous = store.usage(for: accountID)
        var snapshot: UsageSnapshot
        var rateLimited = false

        switch result {
        case .success(let windows):
            snapshot = UsageSnapshot(windows: windows, fetchedAt: fetchedAt,
                                     lastEndpointFetchAt: fetchedAt)
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
        // A usage observation is the tail of a request that already reported its head.
        // It carries no headers and no verdict — only what the request cost.
        if let billed = observation.usage {
            recordSpend(billed, model: observation.model,
                        accountID: observation.accountID, sessionID: sessionID)
            return
        }

        let isAPIKey = store.accounts.get(observation.accountID)?.kind == .apiKey
        let fromHeaders = isAPIKey
            ? UsageParser.apiWindowsFromResponseHeaders(observation.headers)
            : UsageParser.windowsFromResponseHeaders(observation.headers)
        if !fromHeaders.isEmpty {
            var snapshot = store.usage(for: observation.accountID) ?? UsageSnapshot()
            for window in fromHeaders { snapshot.windows.upsert(window) }
            snapshot.fetchedAt = Date()
            snapshot.lastError = nil
            store.setUsage(snapshot, for: observation.accountID)
            evaluateThresholds(for: observation.accountID, snapshot: snapshot)
        }

        guard UsageParser.isRateLimited(headers: observation.headers,
                                        statusCode: observation.statusCode) else {
            if blocks.served(sessionID: sessionID, accountID: observation.accountID,
                             model: observation.model) {
                retractBanner(owner: sessionID)
            }
            return
        }
        // The response may belong to a request that was already on the wire when the
        // account changed. Its usage still counts against the account that served it,
        // but moving the session on it would undo a choice just made.
        guard store.sessions.get(sessionID)?.accountID == observation.accountID else {
            Log.info("ignoring a rate-limit response for \(observation.accountID); "
                     + "session \(sessionID) has already moved on")
            return
        }
        // Same reasoning as the failover path: an API key reports per-minute ceilings, so
        // a 429 means "wait a moment", not "this account is spent". Treating it as
        // exhaustion would rehome the session and strand the user's choice.
        guard store.accounts.get(observation.accountID)?.kind != .apiKey else { return }
        handleExhaustion(sessionID: sessionID, accountID: observation.accountID,
                         model: observation.model)
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

    private func handleExhaustion(sessionID: String, accountID: String, model: String?) {
        guard let record = store.sessions.get(sessionID) else { return }
        let accountName = displayName(accountID)

        // At a turn boundary the switch waits for Claude Code to stop working, so the
        // prompt cache is dropped between turns rather than mid-answer.
        if settings.autoSwitch == .atTurnBoundary, isBusy(pid: record.pid) {
            if pendingSwitch[sessionID] == nil {
                pendingSwitch[sessionID] = (accountID, Date(), model)
                Log.info("session \(sessionID) will move off \(accountID) at its next "
                         + "turn boundary")
            }
            return
        }
        performSwitch(sessionID: sessionID, from: accountID, accountName: accountName,
                      model: model)
    }

    private func performSwitch(sessionID: String, from accountID: String,
                               accountName: String, model: String?) {
        switch sessionManager.reassignAfterExhaustion(sessionID: sessionID,
                                                      globallyEnabled: settings.autoSwitch != .off) {
        case .switched(_, let to):
            unblock(sessionID: sessionID)
            if settings.notifyOnAutoSwitch {
                notifier.post(title: "Switched to \(displayName(to))",
                              body: "\(accountName) hit its limit; "
                                  + "\(sessionLabel(sessionID)) moved on its next request.")
            }
        case .disabled:
            block(sessionID: sessionID, accountID: accountID, model: model,
                  reason: .pinned, title: "\(accountName) is out of headroom",
                  body: "\(sessionLabel(sessionID)) is blocked. "
                      + "Pick another account in ccmux.")
        case .noneEligible:
            block(sessionID: sessionID, accountID: accountID, model: model,
                  reason: .noneEligible, title: "No account left with headroom",
                  body: "\(accountName) hit its limit and nothing else "
                      + "satisfies its policy.")
        case .failed(let reason):
            Log.error("auto-switch failed for session \(sessionID): \(reason)")
            banner = Banner(level: .warning, text: "Could not move "
                            + "\(sessionLabel(sessionID)): \(reason)")
        }
    }

    /// Blocks live in memory, so a restart while a session sits parked would drop the
    /// badge until the next refusal — which may be hours away. Only a fully exhausted
    /// account qualifies here: an inferred block must not fire on an account that is
    /// merely low. The model is unknown at rest, so any success clears it.
    private func restoreBlocks() {
        let accounts = store.accounts.all()
        let usage = store.allUsage()
        for record in store.sessions.all() {
            guard !ModelRouting.canServe(nil, usage: usage[record.accountID]) else { continue }
            let movable = record.autoSwitchEnabled(default: settings.autoSwitch != .off)
            if movable {
                let elsewhere = PolicyEngine.pick(accounts: accounts.filter(\.isAutoAssignable),
                                                  usage: usage,
                                                  policy: PolicyEngine.everyWindow,
                                                  excluding: [record.accountID])
                guard elsewhere == nil else { continue }
            }
            blocks.block(sessionID: record.id, accountID: record.accountID, model: nil,
                         reason: movable ? .noneEligible : .pinned)
        }
        if !blocks.isEmpty {
            Log.info("restored \(blocks.count) blocked session(s) after launch")
        }
    }

    private func recordSpend(_ billed: TokenUsage, model: String?,
                             accountID: String, sessionID: String) {
        guard let account = store.accounts.get(accountID), account.kind == .apiKey,
              let model else { return }
        guard let cost = Pricing.cost(model: model, usage: billed), cost > 0 else {
            // Better an admitted gap than an invented price: the total would otherwise
            // read as complete while quietly omitting these requests.
            if Pricing.price(for: model) == nil {
                unpricedModels.insert(model)
                Log.warn("no listed price for \(model); its usage is missing from the "
                         + "spend total for \(displayName(accountID))")
            }
            return
        }
        store.sessions.mutate(sessionID) { $0.spendUSD += cost }
        store.accounts.mutate(accountID) {
            $0.spendLifetimeUSD += cost
            var month = $0.spendThisMonth
                ?? MonthlySpend(month: MonthlySpend.monthKey(), amountUSD: 0)
            month.add(cost)
            $0.spendThisMonth = month
        }
        evaluateBudget(accountID)
    }

    /// The budget is advisory: it warns once per month per crossing and never withholds a
    /// request. Blocking would strand whatever session is on the key with nowhere to go.
    private func evaluateBudget(_ accountID: String) {
        guard let account = store.accounts.get(accountID),
              let budget = account.monthlyBudgetUSD, budget > 0,
              let window = Engine.budgetWindow(for: account), window.percent >= 100
                  || window.percent >= settings.budgetWarnPercent
        else { return }
        let spent = account.spendThisMonth?.amount() ?? 0
        notifier.postOnce(
            key: "budget/\(accountID)/\(MonthlySpend.monthKey())/"
                + (window.percent >= 100 ? "over" : "warn"),
            title: window.percent >= 100
                ? "\(account.displayName) is over budget"
                : "\(account.displayName) is near its budget",
            body: String(format: "$%.2f of $%.2f this month.", spent, budget))
    }

    /// Spend against the monthly budget, shaped as a window so it draws as one more bar.
    public static func budgetWindow(for account: Account,
                                    now: Date = Date()) -> UsageWindow? {
        guard let budget = account.monthlyBudgetUSD, budget > 0 else { return nil }
        let spent = account.spendThisMonth?.amount(inMonthOf: now) ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                      from: now))
        let resets = startOfMonth.flatMap {
            calendar.date(byAdding: DateComponents(month: 1), to: $0)
        }
        return UsageWindow(kind: .budget,
                           label: String(format: "Budget $%.0f", budget),
                           percent: min(100, spent / budget * 100), resetsAt: resets)
    }

    private func block(sessionID: String, accountID: String, model: String?,
                       reason: BlockLedger.Entry.Reason, title: String, body: String) {
        guard blocks.block(sessionID: sessionID, accountID: accountID, model: model,
                           reason: reason) else { return }
        banner = Banner(level: .warning, text: "\(title). \(body)",
                        source: .blockedSession(sessionID))
        notifier.postOnce(key: "blocked/\(sessionID)/\(accountID)/\(periodStamp(accountID))",
                          title: title, body: body)
    }

    private func unblock(sessionID: String) {
        guard blocks.unblock(sessionID) else { return }
        retractBanner(owner: sessionID)
    }

    /// A banner naming a session that has recovered is worse than none: it hands the
    /// blame to the wrong session while another is still stuck.
    private func retractBanner(owner sessionID: String) {
        guard banner?.source == .blockedSession(sessionID) else { return }
        guard let next = blocks.all.first else {
            banner = nil
            return
        }
        banner = Banner(level: .warning,
                        text: "\(displayName(next.accountID)) is out of headroom. "
                            + "\(sessionLabel(next.sessionID)) is blocked.",
                        source: .blockedSession(next.sessionID))
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
                          accountName: displayName(pending.accountID),
                          model: pending.model)
        }
    }

    /// Re-picks accounts for sessions on demand, answering "where would these launch if
    /// I started them now". Nothing does this on a timer: a session stays where it is
    /// until it is refused or until this is asked for.
    public func reassignSessions(scope: Rebalance.Scope) {
        let plan = Rebalance.plan(sessions: store.sessions.all(),
                                  accounts: store.accounts.all(), usage: store.allUsage(),
                                  settings: settings, live: liveByPID, scope: scope)
        var moved = 0
        var failed = 0
        for move in plan.moves {
            do {
                try sessionManager.assign(sessionID: move.sessionID, accountID: move.to)
                pendingSwitch.removeValue(forKey: move.sessionID)
                unblock(sessionID: move.sessionID)
                moved += 1
            } catch {
                failed += 1
                Log.warn("could not reassign session \(move.sessionID): "
                         + "\(error.localizedDescription)")
            }
        }
        raise(Rebalance.report(moved: moved, failed: failed, skipped: plan.skipped),
              level: failed > 0 ? .warning : .info)
    }

    /// Shows a transient message without burying a blocked-session warning. A banner
    /// with no source replacing one that has a source leaves `retractBanner` unable to
    /// bring it back, so the blocked session goes unannounced until its next refusal.
    private func raise(_ text: String, level: Banner.Level,
                       action: Banner.Action? = nil) {
        guard let stuck = blocks.all.first else {
            banner = Banner(level: level, text: text, action: action)
            return
        }
        banner = Banner(level: .warning,
                        text: text + " \(displayName(stuck.accountID)) is still out of "
                            + "headroom; \(sessionLabel(stuck.sessionID)) is blocked.",
                        action: action, source: .blockedSession(stuck.sessionID))
    }

    /// What a reassign would do right now, so the menu can name the number instead of
    /// making the user press it to find out.
    public func reassignPreview(scope: Rebalance.Scope) -> Int {
        Rebalance.plan(sessions: sessions, accounts: accounts, usage: usage,
                       settings: settings, live: liveByPID, scope: scope).moves.count
    }

    private func isBusy(pid: Int32) -> Bool {
        claudeSession(forPID: pid)?.status == "busy"
    }

    func displayName(_ accountID: String) -> String {
        store.accounts.get(accountID)?.displayName ?? accountID
    }

    private func handleRefreshFailure(_ accountID: String, _ error: OAuthError) {
        guard error.isPermanent else {
            // A delegated account is renewed from ccmuxd, so blaming Anthropic would send
            // you looking in the wrong place.
            let upstream = settings.delegated.contains(accountID)
                ? "the account server" : "Anthropic"
            banner = Banner(level: .warning,
                            text: "Could not reach \(upstream) for "
                                + "\(displayName(accountID)): \(error.localizedDescription)")
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

    /// Brings a session's terminal tab to the front. Nothing is stored for this: the
    /// handle is read from the process when it is asked for, so it works on sessions
    /// started before the feature existed and on ones ccmux did not launch.
    public func revealInTerminal(pid: Int32) {
        // Off the main thread on purpose. The first press raises the Automation consent
        // dialog, and `osascript` does not return until it is answered — on main that
        // freezes the whole window behind the very prompt asking to proceed.
        let label = sessionLabel(forPID: pid)
        Task.detached {
            let outcome = TerminalOpener.open(pid: pid)
            Log.info("reveal \(label) (pid \(pid)) -> \(outcome)")
            guard let message = outcome.message else { return }
            await MainActor.run { [weak self] in
                self?.raise(message, level: .warning,
                            action: outcome == .denied ? .openAutomationSettings : nil)
            }
        }
    }

    public var canRevealInTerminal: Bool { TerminalOpener.isITermInstalled }

    public func openAutomationSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.preference.security"
                              + "?Privacy_Automation",
                          "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
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

    /// Signs an account in again, reusing everything already known about it — including
    /// its Chrome profile, which is the whole point of that setting.
    /// Puts back a `kind` the record lost. Runs at launch because the damage is silent:
    /// an API key recorded as a subscription is picked automatically by the policy engine
    /// and then fails to seed, which surfaces as a sign-in prompt for an account that
    /// never had a sign-in.
    private func repairAccountKinds() {
        for account in store.accounts.all() {
            let key = (try? APIKeyStore.read(account.id)) ?? nil
            guard account.contradictsStoredAPIKey(hasStoredAPIKey: !(key ?? "").isEmpty)
            else { continue }
            store.accounts.mutate(account.id) {
                $0.kind = .apiKey
                // Never re-enter rotation on its own: an API key costs money per token,
                // so it is only ever used when a session is assigned to it deliberately.
                $0.inRotation = false
            }
            Log.warn("repaired \(account.displayName): an API-key account was recorded as "
                     + "a subscription in rotation")
            // On screen, not only in the log: the account silently stops being picked,
            // and an unexplained change of behaviour reads as a bug.
            banner = Banner(level: .warning,
                            text: "\(account.displayName) was recorded as a subscription "
                                + "but holds an API key. It has been put back and taken "
                                + "out of rotation, so nothing spends it by accident.")
        }
    }

    public func relogin(accountID: String) {
        guard let account = store.accounts.get(accountID) else { return }
        // Whether the code is redeemed here or on the server is decided inside
        // `startLogin` from the delegation set, so every caller looks the same.
        Task {
            await startLogin(accountID: accountID, label: account.label,
                             loginHint: account.email,
                             chromeProfileDirectory: account.chromeProfileDirectory)
        }
    }

    /// Repairs an account whose plan never landed on its record. Until it does, every
    /// session on that account is seeded with a credential Claude Code reads as having no
    /// entitlements, which silently withholds models the plan actually includes.
    private func backfillMissingPlans() async {
        for account in store.accounts.all()
        where account.kind == .subscription
            && (account.subscriptionType == nil || account.rateLimitTier == nil) {
            guard account.health != .needsRelogin,
                  let token = vault.cachedBearerToken(for: account.id),
                  let identity = try? await client.profile(accessToken: token),
                  identity.subscriptionType != nil || identity.rateLimitTier != nil
            else { continue }

            store.accounts.mutate(account.id) {
                $0.subscriptionType = $0.subscriptionType ?? identity.subscriptionType
                $0.rateLimitTier = $0.rateLimitTier ?? identity.rateLimitTier
            }
            Log.info("backfilled plan for \(displayName(account.id)): "
                     + "\(identity.subscriptionType ?? "?")")
            // Live sessions are holding the unentitled credential right now, and only a
            // re-seed puts the plan in front of them without a restart.
            if let credential = vault.credential(for: account.id) {
                sessionManager.reseedNamespaces(accountID: account.id, credential: credential)
            }
        }
    }

    func adopt(credential: OAuthCredential, chromeProfileDirectory: String?,
                       label: String?) async throws -> Account {
        let identity = try await client.profile(accessToken: credential.accessToken)
        var account = store.accounts.get(identity.uuid)
            ?? Account(id: identity.uuid, label: label ?? identity.email ?? identity.uuid)
        if let label, !label.isEmpty { account.label = label }
        account.email = identity.email ?? account.email
        account.organizationUUID = identity.organizationUUID
        account.organizationName = identity.organizationName ?? account.organizationName
        // The profile is the fallback, not an afterthought: a token exchange can hand
        // back a credential with no plan on it at all, and an account left without one
        // seeds sessions that Claude Code reads as having no entitlements.
        account.subscriptionType = credential.subscriptionType
            ?? identity.subscriptionType ?? account.subscriptionType
        account.rateLimitTier = credential.rateLimitTier
            ?? identity.rateLimitTier ?? account.rateLimitTier
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

    /// Adds an API key as an account. The key is verified before anything is stored, so
    /// a typo fails here rather than as a puzzling 401 on the user's next request.
    public func addAPIKeyAccount(key: String, label: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            banner = Banner(level: .warning, text: "Paste an API key first.")
            return false
        }
        loginInProgress = true
        defer { loginInProgress = false }
        do {
            let models = try await client.validateAPIKey(trimmed)
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = UUID().uuidString
            var account = Account(id: id, label: name.isEmpty ? "API key" : name,
                                  kind: .apiKey)
            account.health = .ok
            account.priority = (store.accounts.all().map(\.priority).max() ?? 0) + 1
            try APIKeyStore.write(trimmed, for: id)
            // The account set has not moved, so nothing else would prompt a re-read.
            apiKeyFingerprints.invalidate()
            store.accounts.upsert(account)
            banner = Banner(level: .info,
                            text: "Added \(account.displayName) · \(models.count) models "
                                + "reachable. Assign a session to it from the Sessions "
                                + "screen — API keys are never picked automatically.")
            return true
        } catch {
            banner = Banner(level: .warning,
                            text: "That key was rejected: \(error.localizedDescription)")
            return false
        }
    }

    /// Points every outbound path at the proxy — the relay, the vault's refresher, and
    /// this engine's own client. A URLSession's proxy is fixed at construction, so each
    /// is rebuilt; in-flight requests drain on the old sessions rather than being cut off.
    public func applyUpstreamProxy() {
        let proxy = settings.upstreamProxy
        let password = try? ProxyPasswordStore.read()
        UpstreamRelay.shared.setProxy(proxy, password: password)
        let proxied = OAuthClient.proxied(proxy, password: password)
        client = proxied
        vault.setClient(proxied)
        // The cached ServerClient is keyed on the connection, which has not changed — but
        // its URLSession fixed the proxy at construction, so it has to be rebuilt too.
        serverClientCache = nil
        applyRemoteToVault()
        if let proxy {
            Log.info("outbound requests now go through \(proxy.displayString)")
        }
    }

    /// Accepts what someone would paste into HTTPS_PROXY. The password is split out and
    /// stored in the Keychain rather than in settings.json, which is plaintext on disk.
    public func setUpstreamProxy(_ raw: String) -> Bool {
        guard let parsed = UpstreamProxy.parse(raw) else {
            banner = Banner(level: .warning,
                            text: "That does not look like a proxy URL. Expected "
                                + "something like http://user:pass@host:3128")
            return false
        }
        do {
            try ProxyPasswordStore.write(parsed.password)
        } catch {
            banner = Banner(level: .warning,
                            text: "Could not store the proxy password: "
                                + error.localizedDescription)
            return false
        }
        updateSettings { $0.upstreamProxy = parsed.proxy }
        applyUpstreamProxy()
        return true
    }

    public func clearUpstreamProxy() {
        try? ProxyPasswordStore.write(nil)
        updateSettings { $0.upstreamProxy = nil }
        applyUpstreamProxy()
    }

    /// One real request through the proxy, so the answer is "it works" or the actual
    /// reason — rather than a silent hang the next time a session needs a token.
    public func testUpstreamProxy() async -> String {
        let proxy = settings.upstreamProxy
        guard proxy != nil else { return "No proxy configured." }
        let password = try? ProxyPasswordStore.read()
        let probe = OAuthClient.proxied(proxy, password: password)
        do {
            _ = try await probe.validateAPIKey("sk-ant-connectivity-probe")
            return "Reached Anthropic through the proxy."
        } catch let error as OAuthError {
            // A 401 is the proxy working perfectly: the tunnel carried our request and
            // Anthropic rejected a deliberately invalid key.
            if case .badResponse(let message) = error,
               message.lowercased().contains("api key") || message.contains("401") {
                return "Proxy works — reached Anthropic (it rejected the dummy key, as expected)."
            }
            return "Proxy failed: \(error.localizedDescription)"
        } catch {
            return "Proxy failed: \(error.localizedDescription)"
        }
    }

    /// Directories bound to an account, newest rules resolved the same way a launch
    /// resolves them, so the screen lists exactly what a session would get.
    public func bindDirectory(_ path: String, to accountID: String) {
        updateSettings { $0.bind(path, to: accountID) }
    }

    public func unbindDirectory(_ path: String) {
        updateSettings { $0.unbind(path) }
    }

    public func setInRotation(_ inRotation: Bool, for accountID: String) {
        store.accounts.mutate(accountID) { $0.inRotation = inRotation }
    }

    public func setMonthlyBudget(_ budgetUSD: Double?, for accountID: String) {
        store.accounts.mutate(accountID) {
            $0.monthlyBudgetUSD = (budgetUSD ?? 0) > 0 ? budgetUSD : nil
        }
    }

    /// What the live sessions on this account have spent, which is not the same as what
    /// the account has spent — ended sessions keep counting toward the lifetime total.
    public func liveSpend(forAccount accountID: String) -> Double {
        sessions.filter { $0.accountID == accountID }.reduce(0) { $0 + $1.spendUSD }
    }

    public func removeAccount(_ accountID: String) {
        for record in store.sessions(forAccount: accountID) {
            sessionManager.endSession(record.id)
        }
        vault.forget(accountID)
        // Leaving the key behind would keep a working credential in the Keychain for an
        // account the user believes they deleted.
        try? APIKeyStore.delete(accountID)
        // Leaving it delegated would route a later re-added account to the server, whose
        // 404 is transient by design — so the fresh local lineage would never be refreshed
        // and the account would quietly stop working when its access token expired.
        if settings.delegated.contains(accountID) {
            updateSettings { $0.delegatedAccountIDs.removeAll { $0 == accountID } }
            applyRemoteToVault()
        }
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

    /// Sessions on this account running on other Macs. Counted apart from
    /// `sessionCount(forAccount:)`, which every caller reads as "running here".
    public func foreignSessionCount(forAccount accountID: String) -> Int {
        foreignSessions.reduce(0) { $0 + ($1.accountID == accountID ? 1 : 0) }
    }

    public func foreignMachineNames(forAccount accountID: String) -> [String] {
        var seen: [String] = []
        for session in foreignSessions where session.accountID == accountID {
            if !seen.contains(session.machineLabel) { seen.append(session.machineLabel) }
        }
        return seen
    }

    // MARK: - Sessions

    public func assign(sessionID: String, to accountID: String) {
        do {
            try sessionManager.assign(sessionID: sessionID, accountID: accountID)
            pendingSwitch.removeValue(forKey: sessionID)
            unblock(sessionID: sessionID)
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    public func setAutoSwitch(_ enabled: Bool, for sessionID: String) {
        store.sessions.mutate(sessionID) { $0.autoSwitchOverride = enabled }
        // The recorded reason said auto-switch was off for this session. It re-blocks with
        // an accurate one on the next refusal.
        if enabled, blocks[sessionID]?.reason == .pinned { unblock(sessionID: sessionID) }
    }

    public func endSession(_ sessionID: String) {
        sessionManager.endSession(sessionID)
    }

    /// Claude Code's own view of every live session, by pid, for the Sessions screen to
    /// order by what each one is actually doing.
    public var liveByPID: [Int32: ClaudeSessionInfo] {
        Dictionary(claudeSessions.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func claudeSession(forPID pid: Int32) -> ClaudeSessionInfo? {
        claudeSessions.first { $0.pid == pid }
    }

    /// The name on the card for a pid, managed or not.
    public func sessionLabel(forPID pid: Int32) -> String {
        claudeSession(forPID: pid)?.name
            ?? store.sessions.all().first { $0.pid == pid }
                .map { Format.shortenHome($0.cwd) }
            ?? "pid \(pid)"
    }

    /// How a session is named on its card, so every other mention of it — curtain row,
    /// banner, notification — points at something the user can actually find.
    public func sessionLabel(_ sessionID: String) -> String {
        guard let record = store.sessions.get(sessionID) else {
            return String(sessionID.prefix(8))
        }
        return claudeSession(forPID: record.pid)?.name ?? Format.shortenHome(record.cwd)
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
