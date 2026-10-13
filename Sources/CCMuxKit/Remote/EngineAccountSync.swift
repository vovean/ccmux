import CCMuxCore
import Foundation

/// Keeps this Mac's accounts and groups in step with the server, without asking.
///
/// A local refresh token is given up only once the server has adopted the lineage, and
/// the server's tokens replace the local credential only once it has proved it can mint
/// one — so an account never ends up with no working credential on either side.
public extension Engine {
    /// `manual` is the Sync now button: it reports even when nothing changed.
    func syncAccounts(manual: Bool = false) async {
        // A click while a background round runs waits for it rather than doing nothing.
        while manual && syncingAccounts {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let client = serverClient, !syncingAccounts else { return }
        syncingAccounts = true
        // Published only for the button: a background round must not redraw the window.
        if manual { serverBusy = true }
        defer {
            syncingAccounts = false
            if manual { serverBusy = false }
        }
        if manual || !serverFeaturesKnown { serverFeaturesAskedAt = nil }
        await refreshServerFeatures(client)
        // Without them a server's shared settings would be read as absent, and a grouped
        // account imported as ungrouped.
        guard serverFeaturesKnown else {
            if manual {
                raise("Could not reach the server to sync.", level: .warning)
            }
            return
        }

        let remote: [RemoteAccount]
        do {
            remote = try await client.accounts()
        } catch {
            guard !Self.isCancellation(error) else { return }
            if !accountSyncFailing {
                accountSyncFailing = true
                Log.warn("account sync failed: " + ServerDiagnostics.describe(error))
            }
            if manual {
                raise("Could not sync with the server: " + error.localizedDescription,
                      level: .warning)
            }
            return
        }
        if serverSupportsGroups { await reloadGroups(client) }

        let local = store.accounts.all()
        // Hidden matters only while there is no local copy; one signed in here since is
        // wanted back.
        let localIDs = Set(local.map(\.id))
        if settings.hiddenAccountIDs.contains(where: localIDs.contains) {
            updateSettings { $0.hiddenAccountIDs.removeAll(where: localIDs.contains) }
        }
        refreshAPIKeyFingerprints()
        let plan = AccountSync.plan(
            local: local, remote: remote, delegated: settings.delegated,
            hidden: Set(settings.hiddenAccountIDs), canUpload: canUpload,
            apiKeyFingerprint: { [apiKeyFingerprints] in apiKeyFingerprints[$0] })
        let outcome = await carryOut(plan, remote: remote, client: client)

        if accountSyncFailing {
            accountSyncFailing = false
            Log.info("account sync recovered")
        }
        lastAccountSync = Date()
        report(outcome, heldBack: plan.heldBackRemovals, manual: manual)
    }

    private struct SyncOutcome {
        var uploaded: [String] = []
        var handedOver = 0
        var imported: [String] = []
        var removed: [String] = []
        var problems: [String] = []
        var awaitingToken: [String] = []
        var needSignIn: [String] = []
    }

    private func carryOut(_ plan: AccountSync.Plan, remote: [RemoteAccount],
                          client: ServerClient) async -> SyncOutcome {
        let catalogue = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var outcome = SyncOutcome()

        // A Disconnect during the round ends it: what is left would act for a server this
        // Mac no longer talks to.
        for action in plan.actions where isStillConnected(to: client) {
            switch action {
            case .upload(let localID):
                guard let account = store.accounts.get(localID) else { continue }
                guard let remoteID = await upload(account, client: client) else {
                    uploadRetryAt[localID] = Date().addingTimeInterval(Self.uploadRetryDelay)
                    noteProblem(account.displayName, &outcome, "could not be uploaded")
                    continue
                }
                uploadRetryAt[localID] = nil
                guard isStillConnected(to: client) else {
                    // Disconnected while the adopt was in flight. The server holds the
                    // lineage now, so this Mac must stop refreshing it all the same. A key
                    // has no lineage and keeps working here.
                    if account.kind == .subscription {
                        surrenderLocalLineage(localID)
                        store.accounts.mutate(localID) {
                            $0.health = .needsRelogin
                            $0.healthDetail = "Uploaded to a server this Mac has "
                                + "disconnected from."
                        }
                    }
                    break
                }
                // The server now holds the lineage. This Mac stops refreshing it before
                // anything else can fail, or both sides would rotate it and the loser
                // would be logged out for good.
                markDelegated(remoteID, client: client)
                surrenderLocalLineage(localID)
                if await handOver(remoteID, localID: localID, client: client) {
                    outcome.uploaded.append(account.displayName)
                } else {
                    // Uploaded and delegated; only the first token fetch failed, and the
                    // next renewal retries it.
                    outcome.awaitingToken.append(account.displayName)
                }

            case .handOver(let localID, let remoteID):
                if await handOver(remoteID, localID: localID, client: client) {
                    if let record = catalogue[remoteID] { mirror(record) }
                    outcome.handedOver += 1
                } else {
                    noteProblem(store.accounts.get(localID)?.displayName ?? localID,
                                &outcome, "could not be handed over")
                }

            case .importAccount(let remoteID):
                guard let record = catalogue[remoteID] else { continue }
                if record.health == .needsRelogin {
                    // A row anyway: without one there is no sign-in button, and no way
                    // to repair the server's lineage from this Mac.
                    adoptRemoteRecord(record)
                    markDelegated(record.id, client: client)
                    outcome.needSignIn.append(record.displayName)
                } else if await importAccount(record, client: client) {
                    outcome.imported.append(record.displayName)
                } else {
                    noteProblem(record.displayName, &outcome, "could not be imported")
                }

            case .remove(let localID):
                let name = store.accounts.get(localID)?.displayName ?? localID
                removeAccountLocally(localID)
                outcome.removed.append(name)

            case .refresh(let remoteID):
                if let record = catalogue[remoteID] { mirror(record) }
            }
        }
        return outcome
    }

    private static let uploadRetryDelay: TimeInterval = 15 * 60

    /// Written per account rather than once per sync: a crash after a local refresh token
    /// is gone must not lose the record that the server owns it now.
    private func markDelegated(_ accountID: String, client: ServerClient) {
        guard !settings.delegated.contains(accountID) else { return }
        commitDelegation(settings.delegated.union([accountID]), client: client)
    }

    /// Logged once per account; the sync retries every minute.
    private func noteProblem(_ name: String, _ outcome: inout SyncOutcome, _ what: String) {
        outcome.problems.append(name)
        if loggedSyncProblems.insert(name).inserted {
            Log.warn("account sync: \(name) \(what); retrying every minute")
        }
    }

    private func report(_ outcome: SyncOutcome, heldBack: [String], manual: Bool) {
        var parts: [String] = []
        if !outcome.uploaded.isEmpty {
            parts.append("uploaded " + outcome.uploaded.joined(separator: ", "))
        }
        if !outcome.imported.isEmpty {
            parts.append("added " + outcome.imported.joined(separator: ", "))
        }
        if !outcome.removed.isEmpty {
            parts.append("removed " + outcome.removed.joined(separator: ", ")
                + " (deleted on the server)")
        }
        if outcome.handedOver > 0 {
            parts.append("\(outcome.handedOver) handed over to the server")
        }
        var warnings: [String] = []
        if !outcome.needSignIn.isEmpty {
            warnings.append("The server needs signing in again for "
                + outcome.needSignIn.joined(separator: ", ") + ".")
        }
        if !outcome.awaitingToken.isEmpty {
            warnings.append("Uploaded, no token yet for "
                + outcome.awaitingToken.joined(separator: ", ") + " — the next renewal retries.")
        }
        if heldBack.isEmpty {
            warnedHeldBackRemovals = false
        } else if !warnedHeldBackRemovals || manual {
            warnedHeldBackRemovals = true
            Log.warn("account sync: the server listed no accounts; kept \(heldBack.count) here")
            warnings.append("The server listed no accounts, so \(heldBack.count) were kept "
                + "on this Mac rather than removed. Check ccmuxd.")
        }
        if manual, !outcome.problems.isEmpty {
            warnings.append("Not synced yet: " + outcome.problems.joined(separator: ", ") + ".")
        }
        guard manual || !parts.isEmpty || !warnings.isEmpty else { return }
        for name in outcome.uploaded + outcome.imported { loggedSyncProblems.remove(name) }
        let summary = parts.isEmpty
            ? "Accounts are in sync with the server."
            : "Synced: " + parts.joined(separator: "; ") + "."
        if !parts.isEmpty { Log.info("account sync: " + parts.joined(separator: "; ")) }
        raise(([summary] + warnings).joined(separator: " "),
              level: warnings.isEmpty ? .info : .warning)
    }

    /// Something the server could adopt — a key, or a lineage that still works — and no
    /// failed attempt waiting out its delay.
    private func canUpload(_ account: Account) -> Bool {
        guard account.health != .needsRelogin,
              (uploadRetryAt[account.id] ?? .distantPast) <= Date() else { return false }
        switch account.kind {
        case .apiKey:
            return apiKeyFingerprints[account.id] != nil
        case .subscription:
            return vault.credential(for: account.id)?.refreshToken?.isEmpty == false
        }
    }

    // MARK: - Moving credentials

    /// Mint, then delete. Asking the server for a token first is what makes this safe: a
    /// server that holds the account but whose own lineage is dead would otherwise leave
    /// the account with no working credential on either side.
    private func handOver(_ remoteID: String, localID: String,
                          client: ServerClient) async -> Bool {
        // `isUsable`, not merely non-nil: the server returns what it holds even when its
        // own refresh failed, and overwriting a working local credential with an expired
        // token destroys the only refresh token this Mac has.
        guard let grant = try? await client.grant(for: remoteID), grant.isUsable,
              // Disconnected while asking: delegating now would undo the disconnect.
              isStillConnected(to: client) else {
            return false
        }

        // Everything the grant must contain is checked before a single local byte is
        // touched. Renumbering deletes the old API key, so a guard failing after it would
        // leave the account with no credential on this Mac at all.
        var replacement: OAuthCredential?
        switch grant.kind {
        case .apiKey:
            guard let key = grant.apiKey, !key.isEmpty else { return false }
            guard writeAPIKey(key, for: remoteID) else { return false }
            if remoteID != localID { renumberAccount(from: localID, to: remoteID) }
        case .subscription:
            guard let credential = grant.credential() else { return false }
            replacement = credential
        }

        // Set before storing: the vault must know not to attempt a local refresh grant on
        // a credential that no longer carries a refresh token.
        markDelegated(remoteID, client: client)
        if let replacement {
            // The local lineage is simply never refreshed again and expires on its own —
            // harmless, because lineages are independent.
            vault.store(replacement, for: remoteID)
            sessionManager.reseedNamespaces(accountID: remoteID, credential: replacement)
        }
        store.accounts.mutate(remoteID) { $0.health = .ok; $0.healthDetail = nil }
        return true
    }

    /// Drops this Mac's refresh token for an account the server has taken over, keeping
    /// the access token so live sessions carry on until the first renewal.
    private func surrenderLocalLineage(_ accountID: String) {
        guard let credential = vault.credential(for: accountID),
              credential.refreshToken != nil else { return }
        var surrendered = credential
        surrendered.refreshToken = nil
        surrendered.refreshTokenExpiresAt = nil
        vault.store(surrendered, for: accountID)
    }

    /// One retry: the usual cause is a transient `security` timeout under contention, and
    /// losing this costs a credential.
    private func writeAPIKey(_ key: String, for accountID: String) -> Bool {
        // A key can change under an id that does not, which the account set alone cannot
        // show — so the fingerprint cache is told directly.
        defer { apiKeyFingerprints.invalidate() }
        for attempt in 1...2 {
            do {
                try APIKeyStore.write(key, for: accountID)
                return true
            } catch where attempt == 2 {
                Log.error("could not store the API key for \(accountID): \(error)")
            } catch {}
        }
        return false
    }

    private func upload(_ account: Account, client: ServerClient) async -> String? {
        var request: AdoptRequest
        switch account.kind {
        case .apiKey:
            // Read here, once: the planner went by the fingerprint cache.
            guard let key = (try? APIKeyStore.read(account.id)) ?? nil, !key.isEmpty else {
                return nil
            }
            request = AdoptRequest(apiKey: key)
        case .subscription:
            // A local refresh during the adopt would rotate the lineage the server just
            // took and leave it holding a dead token, so one that is due runs first.
            if let expiresAt = vault.credential(for: account.id)?.expiresAt,
               expiresAt.timeIntervalSinceNow < Self.uploadTokenMargin {
                guard await vault.refresh(account.id) != nil else { return nil }
            }
            guard let credential = vault.credential(for: account.id),
                  credential.refreshToken?.isEmpty == false else { return nil }
            request = AdoptRequest(credentialJSON: credential.jsonString())
        }
        request.label = account.label.isEmpty ? nil : account.label
        request.inRotation = account.inRotation
        request.monthlyBudgetUSD = account.monthlyBudgetUSD
        if let adopted = try? await client.adopt(request) { return adopted.id }
        // The adopt may well have succeeded and only its answer been lost — the client
        // gives up at 20s and the server can take longer. Assuming failure is the one
        // reading that leaves both sides holding the lineage.
        guard let remote = try? await client.accounts() else { return nil }
        return AccountSync.adopted(account, in: remote,
                                   keyFingerprint: request.apiKey?.apiKeyFingerprint)?.id
    }

    private static let uploadTokenMargin: TimeInterval = 30 * 60

    /// A new record whose first token fails is taken back out: left in, it would be an
    /// account a launch can choose with no credential behind it.
    internal func importAccount(_ remote: RemoteAccount, client: ServerClient) async -> Bool {
        let existed = store.accounts.get(remote.id) != nil
        adoptRemoteRecord(remote)
        guard await handOver(remote.id, localID: remote.id, client: client) else {
            // Unless another import of it got its token meanwhile.
            if !existed && !settings.delegated.contains(remote.id) {
                store.removeAccount(remote.id)
            }
            return false
        }
        return true
    }

    /// Creates the local record for a server account if there is none, then mirrors it.
    /// Carries no credential — that is `handOver`'s job.
    private func adoptRemoteRecord(_ remote: RemoteAccount) {
        if store.accounts.get(remote.id) == nil {
            var account = Account(id: remote.id, label: remote.label, kind: remote.kind)
            account.priority = (store.accounts.all().map(\.priority).max() ?? 0) + 1
            store.accounts.upsert(account)
        }
        mirror(remote, creating: true)
    }

    /// Copies what the server owns into the local record, writing only when it differs.
    /// The shared settings come along only from a server that keeps them; an older one
    /// knows nothing of them, and its silence must not reset what is set here.
    private func mirror(_ remote: RemoteAccount, creating: Bool = false) {
        guard var account = store.accounts.get(remote.id) else { return }
        let before = account
        account.email = remote.email
        account.organizationUUID = remote.organizationUUID
        account.organizationName = remote.organizationName
        account.subscriptionType = remote.subscriptionType ?? account.subscriptionType
        account.rateLimitTier = remote.rateLimitTier ?? account.rateLimitTier
        account.kind = remote.kind
        account.health = remote.health
        account.healthDetail = remote.healthDetail
        if creating || serverSupportsGroups { account.label = remote.label }
        if serverSupportsGroups {
            account.inRotation = remote.inRotation ?? true
            account.monthlyBudgetUSD = remote.monthlyBudgetUSD
            account.groupIDs = remote.groups
        }
        if account != before { store.accounts.upsert(account) }
    }

    /// An API-key account's id is generated by whichever Mac added it. When the server
    /// knows the same key under another id, the record moves, and so does everything on
    /// this Mac that names it. A record already under the new id is the same key, so the
    /// old one folds into it.
    private func renumberAccount(from oldID: String, to newID: String) {
        guard var account = store.accounts.get(oldID) else { return }
        if var existing = store.accounts.get(newID) {
            existing.absorbSpend(of: account)
            store.accounts.upsert(existing)
        } else {
            account.id = newID
            store.accounts.upsert(account)
        }
        let affected = Set((store.sessions(forAccount: oldID)
                            + store.sessions(seededBy: oldID)).map(\.id))
        for sessionID in affected {
            store.sessions.mutate(sessionID) { $0.renumberAccount(from: oldID, to: newID) }
        }
        updateSettings { $0.renumberAccount(from: oldID, to: newID) }
        store.removeAccount(oldID)
        try? APIKeyStore.delete(oldID)
    }

    // MARK: - Removing

    /// Removes the account from this Mac and nowhere else. Live sessions on it end, as
    /// they would on any removal: nothing here could renew their credential any more.
    internal func removeAccountLocally(_ accountID: String) {
        let affected = Set((store.sessions(forAccount: accountID)
                            + store.sessions(seededBy: accountID)).map(\.id))
        for id in affected {
            sessionManager.endSession(id)
        }
        vault.forget(accountID)
        // Leaving the key behind would keep a working credential in the Keychain for an
        // account the user believes they deleted.
        try? APIKeyStore.delete(accountID)
        // Left delegated, a later re-added account would be routed to the server, whose
        // 404 is transient by design — and its fresh local lineage would never refresh.
        if settings.delegated.contains(accountID) {
            updateSettings { $0.delegatedAccountIDs.removeAll { $0 == accountID } }
            applyRemoteToVault()
        }
        store.removeAccount(accountID)
    }

    /// `everywhere` deletes it on the server too, and every other machine drops it at its
    /// next sync. Otherwise it is remembered here so the sync does not bring it back.
    func removeAccount(_ accountID: String, everywhere: Bool) async {
        if everywhere, let client = serverClient {
            do {
                try await client.deleteAccount(accountID)
            } catch ServerClientError.http(404, _) {
                // Not there, which is the outcome asked for.
            } catch {
                raise("Could not delete it on the server, so nothing was removed: "
                          + error.localizedDescription, level: .warning)
                return
            }
        } else if serverClient != nil {
            updateSettings {
                if !$0.hiddenAccountIDs.contains(accountID) {
                    $0.hiddenAccountIDs.append(accountID)
                }
            }
        }
        removeAccountLocally(accountID)
    }

    /// Brings back every account removed from this Mac only.
    func restoreHiddenAccounts() async {
        updateSettings { $0.hiddenAccountIDs = [] }
        await syncAccounts(manual: true)
    }

    // MARK: - Shared settings

    /// Whether a change to this account's shared settings goes to the server first.
    func sharesSettings(_ accountID: String) -> Bool {
        serverSupportsGroups && serverClient != nil && settings.delegated.contains(accountID)
    }

    /// Server first, so two Macs cannot each believe their own value: the local record
    /// takes whatever the server answers with. An account the server does not hold yet
    /// changes here, and its upload carries the change.
    func updateShared(_ accountID: String, _ update: AccountUpdate) async {
        guard sharesSettings(accountID), let client = serverClient else {
            store.accounts.mutate(accountID) { update.apply(to: &$0) }
            return
        }
        do {
            mirror(try await client.updateAccount(accountID, update))
        } catch {
            raise("Could not save the change on the server: " + error.localizedDescription,
                  level: .warning)
        }
    }

    // MARK: - Groups

    func setMembership(_ groupID: String, member: Bool, for accountID: String) async {
        guard let client = groupEditor(for: accountID) else { return }
        do {
            mirror(try await client.setMembership(groupID, of: accountID, member: member))
        } catch {
            raise("Could not change the account's groups: " + error.localizedDescription,
                  level: .warning)
        }
    }

    /// The client to edit this account's groups through, or nil after saying why not.
    private func groupEditor(for accountID: String) -> ServerClient? {
        guard serverSupportsGroupSets else {
            raise("This ccmuxd keeps one group per account. Upgrade it to put an account "
                  + "in several.", level: .warning)
            return nil
        }
        guard sharesSettings(accountID), let client = serverClient else {
            raise("Groups live on the account server, and this account is not on it yet.",
                  level: .warning)
            return nil
        }
        return client
    }

    /// Creates the group, or finds it if the name is taken, and adds the account to it.
    func createGroup(named name: String, adding accountID: String) async {
        guard let client = groupEditor(for: accountID) else { return }
        do {
            let group = try await client.createGroup(named: name)
            await reloadGroups(client, including: group)
            mirror(try await client.setMembership(group.id, of: accountID, member: true))
        } catch {
            raise("Could not create the group: \(error.localizedDescription)", level: .warning)
        }
    }

    func renameGroup(_ groupID: String, to name: String) async {
        guard let client = serverClient else { return }
        do {
            await reloadGroups(client, including: try await client.renameGroup(groupID, to: name))
        } catch {
            raise("Could not rename the group: \(error.localizedDescription)", level: .warning)
        }
    }

    /// Taken off every account on every machine; one in no other group becomes ungrouped.
    func deleteGroup(_ groupID: String) async {
        guard let client = serverClient else { return }
        do {
            try await client.deleteGroup(groupID)
        } catch ServerClientError.http(404, _) {
        } catch {
            raise("Could not delete the group: \(error.localizedDescription)", level: .warning)
            return
        }
        for account in store.accounts.all() where account.groupIDs.contains(groupID) {
            store.accounts.mutate(account.id) { $0.groupIDs.removeAll { $0 == groupID } }
        }
        store.groups.replaceAll(store.groups.all().filter { $0.id != groupID })
        await reloadGroups(client)
    }

    /// The server's list, in its order. `including` stands in when the read fails, so a
    /// group just created or renamed shows at once either way.
    private func reloadGroups(_ client: ServerClient,
                              including changed: SubscriptionGroup? = nil) async {
        var groups: [SubscriptionGroup]
        if let fetched = try? await client.groups() {
            groups = fetched
        } else {
            guard let changed else { return }
            groups = store.groups.all().filter { $0.id != changed.id } + [changed]
        }
        store.groups.replaceAll(groups)
        let known = Set(groups.map(\.id))
        if settings.collapsedAccountGroups.contains(where: { !known.contains($0) }) {
            updateSettings { $0.collapsedAccountGroups.removeAll { !known.contains($0) } }
        }
    }

    /// Nil limits this Mac to accounts in no group.
    func restrictToGroup(_ groupID: String?) {
        updateSettings { $0.restrictedGroupID = groupID }
    }

    func setGroupCollapsed(_ groupID: String, _ collapsed: Bool) {
        updateSettings {
            $0.collapsedAccountGroups.removeAll { $0 == groupID }
            if collapsed { $0.collapsedAccountGroups.append(groupID) }
        }
    }
}
