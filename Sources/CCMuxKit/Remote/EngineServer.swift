import CCMuxCore
import Foundation

/// Connecting this Mac to a ccmuxd, and everything that follows from it.
///
/// The rule the whole file is arranged around: a delegated account's refresh lineage
/// belongs to the server and to nothing else. So the local refresh token is discarded
/// only *after* the server has proved it can mint a token for that account, and the vault
/// is told the account is delegated before the local credential is replaced — otherwise
/// the next renewal would run a refresh grant with no refresh token and report a healthy
/// account as needing re-login.
public extension Engine {
    // MARK: - Connecting

    var serverClient: ServerClient? {
        guard let connection = settings.server else {
            serverClientCache = nil
            return nil
        }
        if let cached = serverClientCache, cached.connection == connection {
            return cached.client
        }
        let urls = connection.addresses.compactMap(URL.init(string:))
        guard !urls.isEmpty,
              let password = (try? ServerPasswordStore.read()) ?? nil else { return nil }
        let client = ServerClient(baseURLs: urls, username: connection.username,
                                  password: password, fingerprint: connection.fingerprint,
                                  proxy: settings.upstreamProxy,
                                  proxyPassword: try? ProxyPasswordStore.read())
        serverClientCache = (connection, client)
        return client
    }

    var isConnectedToServer: Bool { settings.server != nil }

    /// Whether `client` still speaks for the connected server. By its pin rather than by
    /// object: a changed address rebuilds the client without changing the server.
    func isStillConnected(to client: ServerClient) -> Bool {
        settings.server?.fingerprint.lowercased() == client.pinnedFingerprint
    }

    /// Step one of first connect: complete a handshake and report the certificate so the
    /// user can confirm it. Sends no credentials — the peer is unverified at this point.
    func probeServer(_ rawURL: String) async -> Result<String, Error> {
        let urls = Self.serverAddresses(rawURL)
        guard !urls.isEmpty else {
            return .failure(ServerClientError.transport("that is not a URL"))
        }
        serverBusy = true
        defer { serverBusy = false }
        Log.info("probing \(urls.map(\.absoluteString).joined(separator: ", ")) "
            + "(typed as \(rawURL))")
        do {
            let found = try await ServerClient.probe(
                baseURLs: urls, proxy: settings.upstreamProxy,
                proxyPassword: try? ProxyPasswordStore.read(), trace: Self.logTrace)
            Log.info("probe saw \(found.fingerprint) at \(found.url.absoluteString)")
            return .success(found.fingerprint)
        } catch {
            Log.warn("probe failed at every address: " + ServerDiagnostics.describe(error))
            return .failure(error)
        }
    }

    /// Both first-connect paths narrate into the log.
    ///
    /// They are user-initiated and rare, and they are the two that could previously fail
    /// with nothing written down anywhere — the banner was the only report, and a banner
    /// is gone by the time anyone asks what happened.
    nonisolated static let logTrace: ServerTrace = { Log.info("server: \($0)") }

    /// Step two: the user has agreed to the fingerprint. Verify the credentials actually
    /// work before writing anything down, then work out what it means for local accounts.
    @discardableResult
    func connectServer(url rawURL: String, username: String, password: String,
                       fingerprint: String) async -> String? {
        let urls = Self.serverAddresses(rawURL)
        guard !urls.isEmpty else { return "that is not a URL" }
        serverBusy = true
        defer { serverBusy = false }

        Log.info("connecting to \(urls.map(\.absoluteString).joined(separator: ", ")) "
            + "as \(username) pinning \(fingerprint.lowercased())")
        let client = ServerClient(baseURLs: urls, username: username, password: password,
                                  fingerprint: fingerprint, proxy: settings.upstreamProxy,
                                  proxyPassword: try? ProxyPasswordStore.read(),
                                  trace: Self.logTrace)
        let remote: [RemoteAccount]
        do {
            _ = try await client.health()
            remote = try await client.accounts()
        } catch {
            Log.warn("connect failed at every address: "
                + ServerDiagnostics.describe(error))
            return error.localizedDescription
        }

        // Written only once the server has answered: a half-saved connection that cannot
        // authenticate is worse than none, because the vault would start treating
        // accounts as delegated to something unreachable.
        do {
            try ServerPasswordStore.write(password)
        } catch {
            return "Could not save the password to the Keychain: \(error.localizedDescription)"
        }
        // Stored with the address that actually answered first, so a later launch on this
        // network does not open with a timeout against one that cannot work here.
        let answered = client.activeBaseURL
        let rest = urls.filter { $0 != answered }.map(\.absoluteString)
        updateSettings {
            $0.server = ServerConnection(url: answered.absoluteString,
                                         alternateURLs: rest, username: username,
                                         fingerprint: fingerprint)
        }
        applyRemoteToVault()
        // Forced: features belong to the server just connected, not to a previous one.
        serverFeaturesAskedAt = nil
        Task { await syncAccounts() }
        Task { await syncSessions() }
        let others = rest.isEmpty ? "" : " (\(rest.count) alternate address(es))"
        banner = Banner(level: .info,
                        text: "Connected to \(answered.host() ?? answered.absoluteString)"
                            + "\(others) · \(remote.count) account(s) available.")
        return nil
    }

    /// Changes the addresses of the server already connected, keeping everything else.
    ///
    /// Deliberately not "disconnect and connect again": disconnecting clears the delegated
    /// set, and a delegated account holds no refresh token on this Mac, so that route
    /// would strand every one of them behind a fresh sign-in to add an address.
    @discardableResult
    func setServerAddresses(_ raw: String) -> String? {
        guard var connection = settings.server else { return "no server is connected" }
        let urls = Self.serverAddresses(raw).map(\.absoluteString)
        guard !urls.isEmpty else { return "that is not a URL" }
        connection.setAddresses(urls)
        let primary = connection.url
        updateSettings { $0.server = connection }
        // The cached client is keyed on the whole connection, so this rebuilds it; the
        // vault has to be handed the new one or delegated renewals keep using the old.
        serverClientCache = nil
        applyRemoteToVault()
        Log.info("ccmuxd addresses set to " + urls.joined(separator: ", "))
        banner = Banner(level: .info,
                        text: urls.count == 1
                            ? "Server address set to \(primary)."
                            : "Server addresses set — \(primary) first, "
                                + "\(urls.count - 1) alternate(s).")
        return nil
    }

    // MARK: - Hooks

    /// Pulls the server's hook set and writes it into `~/.claude/hooks/managed`.
    ///
    /// Nothing is registered and nothing is run: the files sit there inert until a hook is
    /// pointed at one by hand. That separation is deliberate — syncing is a background
    /// tick, and a background tick should not be able to make this Mac start executing
    /// something new on its own.
    func syncHooks() async {
        guard settings.syncManagedHooks, let client = serverClient else { return }
        guard !syncingHooks else { return }
        syncingHooks = true
        defer { syncingHooks = false }

        // Capabilities come from `HealthResponse.features`, not from which routes 404.
        // The 404 path below stays as a fallback for a server that serves hooks but
        // predates the advertisement.
        await refreshServerFeatures(client)
        if serverSupportsHooks == false {
            clearHookState()
            return
        }

        let bundle: HookBundle
        do {
            bundle = try await client.hooks()
            if serverSupportsHooks != true { serverSupportsHooks = true }
        } catch ServerClientError.unsupported {
            // Kept on the tick rather than latched off, like session sharing: upgrading
            // the server should start working without touching the client.
            // Cleared on the transition only: doing it every tick blanks the page a
            // minute after it fills itself from disk, and it only refills on appear.
            if serverSupportsHooks != false {
                serverSupportsHooks = false
                clearHookState()
            }
            // Cleared here too. Latching only on the success path left the flag stuck
            // after a server downgrade, and the next genuine failure was never logged.
            clearHookSyncFailure()
            return
        } catch {
            // The Hooks page starts one of these and SwiftUI cancels it on navigation
            // away, which is not an outage and must not latch one.
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            if !hookSyncFailing {
                hookSyncFailing = true
                Log.info("hook sync failed: \(error.localizedDescription)")
            }
            return
        }
        clearHookSyncFailure()
        await reconcileHooks(with: bundle)
    }

    /// Off the main actor: this walks the directory, reads and hashes every hook, then
    /// writes and swaps. In-line it would stall the UI on every tick — unboundedly on a
    /// network home directory.
    private func reconcileHooks(with bundle: HookBundle) async {
        let files = bundle.files
        let version = bundle.version
        let result = await Task.detached(priority: .utility) {
            HookSync.reconcile(server: files, serverVersion: version)
        }.value

        hookStatus = HookStatus(hooks: result.hooks, checkedAt: Date(),
                                serverVersion: bundle.version)

        if let failure = result.failure {
            // Latched like the fetch failure. A permanent one — a path the user chmod'd,
            // the managed directory replaced by something else — would otherwise write a
            // warning every minute and bury the lines that matter.
            if !hookApplyFailing {
                hookApplyFailing = true
                Log.warn("could not apply hooks: \(failure)")
            }
            return
        }
        hookApplyFailing = false
        await registerHooks(from: bundle, installed: result.hooks)
        if result.applied {
            Log.info("hooks synced to \(bundle.version.prefix(12)): "
                + "\(result.written.count) written, \(result.removed.count) removed")
        } else if hookStatus.frozen, !loggedHookFreeze {
            loggedHookFreeze = true
            Log.info("hook sync held: \(hookStatus.undecided.map(\.path).joined(separator: ", "))"
                + " changed on this Mac — resolve on the Hooks page")
        }
        if !hookStatus.frozen { loggedHookFreeze = false }
    }

    /// Points Claude Code at the scripts the server marks active, and only when the user
    /// has turned that on.
    ///
    /// Restricted to scripts actually on disk: registering one the sync has not written —
    /// because it is held, or because it never arrived — would point Claude Code at a
    /// path that does not exist.
    private func registerHooks(from bundle: HookBundle, installed: [ManagedHook]) async {
        guard settings.registerManagedHooks else { return }
        let onDisk = Set(installed.compactMap { $0.local == nil ? nil : $0.path })
        // Only scripts actually written: registering one the sync is holding back would
        // point Claude Code at a path that does not exist.
        await applyRegistration(bundle.files.filter { $0.active && onDisk.contains($0.path) }
            .map(\.path))
    }

    /// Serialised through one chain. Three paths reach this — the tick, an Active toggle
    /// and the switch itself — and each suspends over a read-modify-write of a file the
    /// user owns, so unordered they lose each other's changes: the classic one being the
    /// switch turned off while a tick that already passed the guard writes the entries
    /// back in.
    private func applyRegistration(_ active: [String]) async {
        let previous = registrationChain
        let file = Paths.claudeHome.appendingPathComponent("settings.json")
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            let outcome = await Task.detached(priority: .utility) { () -> Result<HookRegistration.Change, Error> in
                do {
                    return .success(try HookRegistration.reconcile(active: active,
                                                                   settingsFile: file))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.recordRegistration(outcome)
            // Cleared so the Engine does not hold the last completed task for the life of
            // the process.
            if self?.registrationChain == nil { return }
        }
        registrationChain = task
        await task.value
        if registrationChain == task { registrationChain = nil }
    }

    private func recordRegistration(_ outcome: Result<HookRegistration.Change, Error>) {
        switch outcome {
        case .success(let change):
            hookRegisterFailing = false
            for path in change.unregisterable where !loggedUnregisterable.contains(path) {
                loggedUnregisterable.insert(path)
                // Otherwise indistinguishable from a hook that simply never fires.
                Log.warn("hook \(path) is active but sits under no known hook event, "
                    + "so nothing was registered for it")
            }
            guard !change.isEmpty else { return }
            // Worth a line every time: this is ccmux changing what Claude Code executes.
            let deduped = change.deduplicated.isEmpty ? ""
                : ", \(change.deduplicated.count) duplicate(s) dropped"
            Log.info("hook registration: \(change.registered.count) added, "
                + "\(change.unregistered.count) removed\(deduped) — takes effect in "
                + "new sessions")
        case .failure(let error):
            if !hookRegisterFailing {
                hookRegisterFailing = true
                Log.warn("could not register hooks: \(error.localizedDescription)")
            }
        }
    }

    func setRegisterManagedHooks(_ on: Bool) {
        updateSettings { $0.registerManagedHooks = on }
        Task {
            // Turning it off takes every managed entry back out, so the switch actually
            // undoes itself rather than only stopping further changes.
            if on { await syncHooks() } else { await unregisterEverything() }
        }
    }

    /// Removes every entry ccmux owns. Ownership is read out of the file itself, so this
    /// works with no server, no sync and nothing left on disk.
    func unregisterEverything() async {
        await applyRegistration([])
    }

    /// Flips one script's registration on the server, for every Mac.
    @discardableResult
    func setHookActive(_ path: String, _ active: Bool) async -> String? {
        guard let client = serverClient else { return "No account server is connected." }
        // The same latch the tick and a resolution take: reconcileHooks below stages and
        // swaps the whole tree, and two of those in flight leave the baseline describing
        // neither.
        guard !syncingHooks else { return "Syncing right now — try again in a moment." }
        syncingHooks = true
        defer { syncingHooks = false }
        do {
            let bundle = try await client.setHookActive(path, active)
            await reconcileHooks(with: bundle)
            return nil
        } catch ServerClientError.unsupported {
            return "This ccmuxd is too old to track which hooks are active."
        } catch {
            return "Could not change \(path): \(error.localizedDescription)"
        }
    }

    /// Settles one file the sync stopped on. Both directions are whole-bundle
    /// operations, since both ends only deal in whole bundles, but each is built so that
    /// answering one question leaves every other unanswered file as it was.
    @discardableResult
    func resolveHook(_ path: String, _ resolution: HookResolution,
                     expectingWithdrawn: Bool = false) async -> String? {
        guard let client = serverClient else { return "No account server is connected." }
        // The same latch the tick takes. Both write the whole tree in one swap, so two of
        // them in flight would each stage from a directory the other is about to replace,
        // and the baseline would end up describing neither.
        guard !syncingHooks else { return "Syncing right now — try again in a moment." }
        syncingHooks = true
        defer { syncingHooks = false }

        // Both sides are re-read here rather than taken from the page's snapshot, which
        // can be a minute old. The snapshot's copy of an *unrelated* file would be written
        // back over an edit made since — through the button next to this one — and
        // recorded as agreed; and its copy of the server's set would drop a hook another
        // Mac published in the meantime, on a route that replaces the whole bundle.
        let fresh: HookBundle
        do {
            fresh = try await client.hooks()
        } catch {
            return "Could not read the server's hooks: \(error.localizedDescription)"
        }
        let hooks = await Task.detached(priority: .utility) {
            HookSync.classify(local: ManagedHooks.onDisk(), server: fresh.files,
                              baseline: HookBaseline.load())
        }.value
        hookStatus = HookStatus(hooks: hooks, checkedAt: Date(),
                                serverVersion: fresh.version)
        guard let hook = hooks.first(where: { $0.path == path }), hook.needsDecision else {
            // Said rather than returned quietly: the button vanishing with no word reads
            // as a click that did not register.
            return "\(path) settled on its own — this Mac and the server now agree."
        }
        // The user confirmed deleting the only copy. Between that and this, someone
        // published the path, so taking the server's copy would be a different act.
        if expectingWithdrawn, hook.server != nil {
            return "\(path) has just been published on the server, so nothing was deleted. "
                + "Download now replaces your copy with theirs."
        }

        switch resolution {
        case .takeServer:
            let tree: [HookFile]
            do {
                tree = try HookSync.treeTakingServer(path, in: hooks)
            } catch {
                return error.localizedDescription
            }
            let server = fresh.files
            let outcome = await Task.detached(priority: .utility) { () -> Result<[ManagedHook], Error> in
                do { return .success(try HookSync.install(tree, server: server).hooks) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let updated):
                hookStatus.hooks = updated
                if !hookStatus.frozen { loggedHookFreeze = false }
                Log.info("hook \(path) taken from the server")
                return nil
            case .failure(let error):
                Log.warn("could not take \(path) from the server: "
                    + error.localizedDescription)
                return "Could not write \(path): \(error.localizedDescription)"
            }

        case .takeLocal:
            guard let files = HookSync.bundlePublishing(path, in: hooks) else {
                return "\(path) is not on this Mac any more."
            }
            do {
                let published = try await client.pushHooks(files)
                Log.info("hook \(path) published as \(published.version.prefix(12))")
                // Re-run the whole reconciliation rather than patching the status: the
                // server now holds this Mac's copy, so the file settles on its own, and
                // any file that was only held back by the freeze can finally land.
                await reconcileHooks(with: published)
                return nil
            } catch {
                Log.warn("could not publish \(path): \(error.localizedDescription)")
                return "Could not publish \(path): \(error.localizedDescription)"
            }
        }
    }

    /// Lists the managed directory when the server has never been reached, so the page
    /// is not blank offline.
    func loadHooksFromDisk() async {
        guard hookStatus.hooks.isEmpty, hookStatus.checkedAt == nil else { return }
        let hooks = await Task.detached(priority: .utility) {
            HookSync.classify(local: ManagedHooks.onDisk(), server: nil,
                              baseline: HookBaseline.load())
        }.value
        guard hookStatus.hooks.isEmpty, hookStatus.checkedAt == nil else { return }
        hookStatus.hooks = hooks
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func clearHookSyncFailure() {
        guard hookSyncFailing else { return }
        hookSyncFailing = false
        Log.info("hook sync recovered")
    }

    func setSyncManagedHooks(_ on: Bool) {
        updateSettings { $0.syncManagedHooks = on }
        guard on else {
            // Only when ccmux put them there. Nothing recomputes the entries once the
            // tick is disabled, so with registration on they would sit in settings.json
            // running scripts the server can no longer withdraw — but with it off ccmux
            // has never written that file, and the hooks in it are the user's own.
            if settings.registerManagedHooks { Task { await unregisterEverything() } }
            clearHookState()
            return
        }
        Task { await syncHooks() }
    }

    /// Reads what the server can do, at most once per interval however many callers ask.
    ///
    /// One probe for every flag rather than one per feature: they all come from a single
    /// `features` array, and two probes meant two round trips for one answer and two
    /// policies that disagreed about how long it stayed true.
    ///
    /// Re-read rather than latched, because the answer changes: upgrading ccmuxd used to
    /// leave hook activation switched off on every Mac until someone quit the app.
    internal func refreshServerFeatures(_ client: ServerClient,
                                        now: Date = Date()) async {
        guard PollPolicy.isDue(lastAsked: serverFeaturesAskedAt,
                               after: ServerAPI.featureProbeInterval, now: now) else {
            return
        }
        // Stamped whether or not it answers, so an unreachable server is not asked on
        // every tick. Nothing is lost by waiting: until an answer arrives the flags stay
        // as they were, and each caller's own route reports an older server itself.
        serverFeaturesAskedAt = now
        // An answer from a server disconnected meanwhile must not undo the reset.
        guard let health = try? await client.health(), isStillConnected(to: client)
        else { return }
        serverFeaturesKnown = true
        // A server older than features has none of them.
        let features = health.features ?? []
        serverSupportsHooks = features.contains(ServerAPI.hooksFeature)
        serverSupportsHookActivation =
            features.contains(ServerAPI.hookActivationFeature)
        serverSupportsUsageSeries = features.contains(ServerAPI.usageSeriesFeature)
        serverSupportsGroups = features.contains(ServerAPI.groupsFeature)
        serverSupportsUsageRefresh = features.contains(ServerAPI.usageRefreshFeature)
        serverSupportsGroupSets = features.contains(ServerAPI.groupSetsFeature)
    }

    func clearHookState() {
        loggedHookFreeze = false
        if hookStatus != HookStatus() { hookStatus = HookStatus() }
    }

    /// Records which address is answering now, so the next launch starts there.
    ///
    /// Called from housekeeping rather than from the request path: the address changes
    /// when a tunnel comes up or goes down, which is rare, and writing settings from
    /// inside every request would be a file write per renewal.
    internal func rememberReachableAddress() {
        guard let client = serverClient, var connection = settings.server else { return }
        let active = client.activeBaseURL.absoluteString
        guard connection.url != active else { return }
        connection.promote(active)
        updateSettings { $0.server = connection }
        Log.info("ccmuxd address preference is now \(active)")
    }

    /// Records a delegation and makes it live, in that order.
    ///
    /// Persisted per account rather than once at the end of a sync: the local refresh
    /// token is stripped inside that loop, so a crash between stripping it and
    /// writing settings would come back with a credential that cannot be refreshed and no
    /// record that it is the server's job now — which presents as a healthy account
    /// suddenly needing re-login.
    internal func commitDelegation(_ delegated: Set<String>, client: ServerClient) {
        updateSettings { $0.delegatedAccountIDs = delegated.sorted() }
        vault.setRemote(client, delegated: delegated)
    }

    /// Hands the vault the current server and the set of accounts it should renew there.
    func applyRemoteToVault() {
        vault.setRemote(serverClient, delegated: settings.delegated)
    }

    func disconnectServer() {
        // Delegated accounts hold an access token and no refresh token, so they cannot be
        // renewed by this Mac at all. Saying so plainly beats leaving them to fail one by
        // one as their tokens age out.
        let stranded = settings.delegatedAccountIDs.compactMap { store.accounts.get($0) }
        updateSettings {
            $0.server = nil
            $0.delegatedAccountIDs = []
        }
        try? ServerPasswordStore.write(nil)
        serverClientCache = nil
        vault.setRemote(nil, delegated: [])
        forgetForeignSessions()
        // Groups are the server's. Kept, a restriction would go on choosing from a group
        // nothing can change any more.
        store.groups.replaceAll([])
        for account in store.accounts.all() where !account.groupIDs.isEmpty {
            store.accounts.mutate(account.id) { $0.groupIDs = [] }
        }
        updateSettings { $0.restrictedGroupID = nil }
        serverSupportsGroups = false
        serverSupportsUsageRefresh = false
        serverSupportsGroupSets = false
        serverFeaturesKnown = false
        lastAccountSync = nil
        // Reset with the rest: left set, the Settings panel keeps telling the user the
        // next server is too old to serve hooks.
        if serverSupportsHooks != nil { serverSupportsHooks = nil }
        if serverSupportsHookActivation { serverSupportsHookActivation = false }
        if serverSupportsUsageSeries != nil { serverSupportsUsageSeries = nil }
        serverFeaturesAskedAt = nil
        usageReportFailing = false
        stats = nil
        statsFetchedAt = nil
        statsError = nil
        // Counted against a server this Mac is no longer talking to, and the next one is
        // a different fleet's ledger.
        stopRecordingUsage()
        hookRegisterFailing = false
        loggedUnregisterable.removeAll()
        lastDelegatedAsk.removeAll()
        hookSyncFailing = false
        hookApplyFailing = false
        // The states are all relative to a server. Keeping them would have the page offer
        // to upload to a server this Mac is no longer connected to.
        clearHookState()
        banner = stranded.isEmpty
            ? Banner(level: .info, text: "Disconnected from the account server.")
            : Banner(level: .warning,
                     text: "Disconnected. \(stranded.count) account(s) were delegated and "
                         + "will need signing in again here: "
                         + stranded.map(\.displayName).joined(separator: ", "))
    }

    // MARK: - Login through the relay

    // MARK: - Usage

    /// Usage for delegated accounts comes from the server's cache. One poller per account
    /// instead of one per Mac: the endpoint budgets ~28 requests an hour per token, and
    /// two Macs polling the same account independently would spend it twice over for the
    /// same numbers.
    ///
    /// `force` is the Refresh button: every account is asked at once, and a server that
    /// can poll on demand is asked to — it applies its own per-account floor.
    func pollDelegatedUsage(force: Bool = false) async {
        guard let client = serverClient else { return }
        let now = Date()
        // The housekeeping tick is every 20s, which is far more often than these numbers
        // move. `serveTTL` is the same floor the app already applies to a locally held
        // snapshot. Counted from when this Mac last asked, not from the age of the
        // answer: ccmuxd caches each account for up to ten minutes, so gating on the
        // data's own age satisfies the floor on every 20s tick — hammering the server and
        // replacing header-fresh numbers with older ones each time.
        let due = settings.delegatedAccountIDs.filter {
            store.accounts.get($0)?.kind == .subscription
                && (force || PollPolicy.shouldAskServer(lastAsked: lastDelegatedAsk[$0],
                                                        now: now))
        }
        // Stamped before the round trip so a slow or failing server is not re-asked by the
        // next tick.
        for accountID in due { lastDelegatedAsk[accountID] = now }
        let onDemand = force && serverSupportsUsageRefresh
        let answers = await withTaskGroup(of: RemoteUsage?.self) { group in
            for accountID in due {
                group.addTask {
                    try? await (onDemand ? client.refreshUsage(for: accountID)
                                         : client.usage(for: accountID))
                }
            }
            var answers: [RemoteUsage] = []
            for await answer in group { if let answer { answers.append(answer) } }
            return answers
        }
        for remote in answers where !remote.windows.isEmpty {
            // Dated by the server's own age, not by when it arrived here. Stamping it now
            // would let a rate-limited server's 20-minute-old numbers look current, and
            // ranking would keep choosing an account that is already exhausted.
            record(.success(remote.windows), for: remote.accountID,
                   fetchedAt: Date().addingTimeInterval(-max(0, remote.ageSeconds)))
        }
    }

    /// Several addresses for one server, separated by commas or whitespace.
    ///
    /// One field rather than a list of them: they are alternates for the same thing, they
    /// are pasted together, and every one of them is checked against the same pin.
    nonisolated static func serverAddresses(_ raw: String) -> [URL] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { normalizeServerURL(String($0)) }
            .filter { seen.insert($0.absoluteString).inserted }
    }

    nonisolated static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host,
              !host.isEmpty else { return nil }
        // A pasted https://user:pass@host is a natural thing to try, and this string is
        // written verbatim into settings.json — the one file the password is deliberately
        // kept out of.
        components.user = nil
        components.password = nil
        if components.port == nil { components.port = 8443 }
        // Trailing path would end up doubled by appendingPathComponent.
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
