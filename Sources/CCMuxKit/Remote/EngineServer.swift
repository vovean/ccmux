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
        guard let url = URL(string: connection.url),
              let password = (try? ServerPasswordStore.read()) ?? nil else { return nil }
        let client = ServerClient(baseURL: url, username: connection.username,
                                  password: password, fingerprint: connection.fingerprint,
                                  proxy: settings.upstreamProxy,
                                  proxyPassword: try? ProxyPasswordStore.read())
        serverClientCache = (connection, client)
        return client
    }

    var isConnectedToServer: Bool { settings.server != nil }

    /// Step one of first connect: complete a handshake and report the certificate so the
    /// user can confirm it. Sends no credentials — the peer is unverified at this point.
    func probeServer(_ rawURL: String) async -> Result<String, Error> {
        guard let url = Self.normalizeServerURL(rawURL) else {
            return .failure(ServerClientError.transport("that is not a URL"))
        }
        serverBusy = true
        defer { serverBusy = false }
        do {
            return .success(try await ServerClient.probeFingerprint(
                baseURL: url, proxy: settings.upstreamProxy,
                proxyPassword: try? ProxyPasswordStore.read()))
        } catch {
            return .failure(error)
        }
    }

    /// Step two: the user has agreed to the fingerprint. Verify the credentials actually
    /// work before writing anything down, then work out what it means for local accounts.
    @discardableResult
    func connectServer(url rawURL: String, username: String, password: String,
                       fingerprint: String) async -> String? {
        guard let url = Self.normalizeServerURL(rawURL) else { return "that is not a URL" }
        serverBusy = true
        defer { serverBusy = false }

        let client = ServerClient(baseURL: url, username: username, password: password,
                                  fingerprint: fingerprint, proxy: settings.upstreamProxy,
                                  proxyPassword: try? ProxyPasswordStore.read())
        let remote: [RemoteAccount]
        do {
            _ = try await client.health()
            remote = try await client.accounts()
        } catch {
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
        updateSettings {
            $0.server = ServerConnection(url: url.absoluteString, username: username,
                                         fingerprint: fingerprint)
        }
        delegationPlan = buildPlan(remote: remote)
        applyRemoteToVault()
        Task { await syncSessions() }
        banner = Banner(level: .info,
                        text: "Connected to \(url.host() ?? url.absoluteString) · "
                            + "\(remote.count) account(s) available.")
        return nil
    }

    /// Recomputes what connecting means, for the connect sheet.
    func refreshDelegationPlan() async {
        guard let client = serverClient else { return }
        serverBusy = true
        defer { serverBusy = false }
        guard let remote = try? await client.accounts() else { return }
        delegationPlan = buildPlan(remote: remote)
    }

    private func buildPlan(remote: [RemoteAccount]) -> Delegation.Plan {
        Delegation.plan(local: store.accounts.all(), remote: remote,
                        delegated: settings.delegated,
                        apiKeyFingerprint: { accountID in
                            guard let key = (try? APIKeyStore.read(accountID)) ?? nil,
                                  !key.isEmpty else { return nil }
                            return key.apiKeyFingerprint
                        })
    }

    /// Records a delegation and makes it live, in that order.
    ///
    /// Persisted per account rather than once at the end of `applyDelegation`: the local
    /// refresh token is stripped inside that loop, so a crash between stripping it and
    /// writing settings would come back with a credential that cannot be refreshed and no
    /// record that it is the server's job now — which presents as a healthy account
    /// suddenly needing re-login.
    private func commitDelegation(_ delegated: Set<String>, client: ServerClient) {
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
        delegationPlan = nil
        forgetForeignSessions()
        banner = stranded.isEmpty
            ? Banner(level: .info, text: "Disconnected from the account server.")
            : Banner(level: .warning,
                     text: "Disconnected. \(stranded.count) account(s) were delegated and "
                         + "will need signing in again here: "
                         + stranded.map(\.displayName).joined(separator: ", "))
    }

    // MARK: - Applying a plan

    /// Executes the plan. `pushing` names the local-only accounts the user ticked; pushing
    /// uploads a refresh token, so it is never inferred.
    func applyDelegation(pushing: Set<String>) async {
        guard let client = serverClient, let plan = delegationPlan else { return }
        serverBusy = true
        defer { serverBusy = false }

        var delegated = settings.delegated
        var pushed = 0, took = 0, imported = 0
        var problems: [String] = []
        var strandedOnServer: [String] = []
        var handedOverPendingToken: [String] = []
        // Fetched once. Doing it per importable account was one full round trip each.
        let catalogue = Dictionary(
            uniqueKeysWithValues: ((try? await client.accounts()) ?? []).map { ($0.id, $0) })

        for entry in plan.entries {
            switch entry.disposition {
            case .alreadyDelegated:
                continue

            case .delegate:
                if await handOver(entry.remoteID ?? entry.id, localID: entry.id,
                                  client: client, delegated: &delegated) {
                    took += 1
                } else {
                    problems.append(entry.displayName)
                }

            case .pushCandidate:
                guard pushing.contains(entry.id) else { continue }
                guard let remoteID = await push(entry, client: client) else {
                    problems.append(entry.displayName)
                    continue
                }
                // The adopt succeeded, so the server is now a holder of this lineage. This
                // Mac must stop refreshing it *before* anything else can fail — otherwise
                // both sides refresh it, and whichever loses is told `invalid_grant` and
                // is logged out for good. Committing here means a failed token fetch below
                // costs a retry, not an account.
                delegated.insert(remoteID)
                commitDelegation(delegated, client: client)
                surrenderLocalLineage(entry.id)
                if await handOver(remoteID, localID: entry.id, client: client,
                                  delegated: &delegated) {
                    pushed += 1
                } else {
                    // Not "left alone": it is on the server and delegated, and this Mac
                    // has already given up its refresh token. Only the first token fetch
                    // failed, and the next renewal retries it.
                    handedOverPendingToken.append(entry.displayName)
                }

            case .serverNeedsRelogin:
                strandedOnServer.append(entry.displayName)
                // A server-only one gets a local row anyway, marked as needing re-login
                // and delegated. Without it there is no Accounts entry, so no sign-in
                // button, so no way to repair the server's lineage from anywhere.
                if store.accounts.get(entry.id) == nil, let remote = catalogue[entry.id] {
                    adoptRemoteRecord(remote)
                    delegated.insert(remote.id)
                    commitDelegation(delegated, client: client)
                }

            case .importable:
                guard let remote = catalogue[entry.id] else {
                    problems.append(entry.displayName)
                    continue
                }
                if await importAccount(remote, client: client, delegated: &delegated) {
                    imported += 1
                } else {
                    problems.append(entry.displayName)
                }
            }
        }

        commitDelegation(delegated, client: client)
        delegationPlan = nil

        var parts: [String] = []
        if took > 0 { parts.append("\(took) delegated") }
        if pushed > 0 { parts.append("\(pushed) pushed up") }
        if imported > 0 { parts.append("\(imported) imported") }
        let summary = parts.isEmpty ? "Nothing changed" : parts.joined(separator: ", ")
        var trailer = ""
        if !problems.isEmpty {
            trailer += " Left alone: " + problems.joined(separator: ", ")
                + " — they still work from this Mac."
        }
        if !handedOverPendingToken.isEmpty {
            trailer += " Handed over but no token yet for "
                + handedOverPendingToken.joined(separator: ", ")
                + " — the server has them and the next renewal retries."
        }
        if !strandedOnServer.isEmpty {
            trailer += " The server needs signing in again for "
                + strandedOnServer.joined(separator: ", ")
                + "."
        }
        banner = trailer.isEmpty
            ? Banner(level: .info, text: summary + ".")
            : Banner(level: .warning, text: summary + "." + trailer)
    }

    /// Mint, then delete. Asking the server for a token first is what makes this safe: a
    /// server that holds the account but whose own lineage is dead would otherwise leave
    /// the account with no working credential on either side.
    private func handOver(_ remoteID: String, localID: String, client: ServerClient,
                          delegated: inout Set<String>) async -> Bool {
        // `isUsable`, not merely non-nil: the server returns what it holds even when its
        // own refresh failed, so a grant can carry a token that expired minutes ago.
        // Overwriting a working local credential with one of those destroys the only
        // refresh token this Mac has.
        guard let grant = try? await client.grant(for: remoteID), grant.isUsable else {
            return false
        }

        // Everything the grant must contain is checked before a single local byte is
        // touched. Renumbering deletes the old API key, so a guard failing after it would
        // leave the account with no credential on this Mac at all.
        var replacement: OAuthCredential?
        switch grant.kind {
        case .apiKey:
            guard let key = grant.apiKey, !key.isEmpty else { return false }
            // Written before the renumber deletes the old item, and checked rather than
            // swallowed: reporting success with no key in the Keychain leaves every
            // session launch on this account failing with `noCredential`.
            guard writeAPIKey(key, for: remoteID) else { return false }
            if remoteID != localID { renumberAPIKeyAccount(from: localID, to: remoteID) }
            delegated.insert(remoteID)
        case .subscription:
            guard let credential = grant.credential() else { return false }
            delegated.insert(remoteID)
            replacement = credential
        }

        // Set before storing: the vault must know not to attempt a local refresh grant on
        // a credential that no longer carries a refresh token.
        commitDelegation(delegated, client: client)
        if let replacement {
            // Overwrites the local credential, which is how the local refresh token stops
            // existing. The lineage it belonged to is simply never refreshed again and
            // expires on its own — harmless, because lineages are independent.
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

    /// One retry, for the same reason `TokenVault.store` has one: the usual cause is a
    /// transient `security` timeout under contention, and losing this costs a credential.
    private func writeAPIKey(_ key: String, for accountID: String) -> Bool {
        // A key can change under an id that does not, which the account set alone cannot
        // show — so the fingerprint cache is told directly.
        defer { apiKeyFingerprints.invalidate() }
        do {
            try APIKeyStore.write(key, for: accountID)
            return true
        } catch {
            do {
                try APIKeyStore.write(key, for: accountID)
                return true
            } catch {
                Log.error("could not store the API key for \(accountID): \(error)")
                return false
            }
        }
    }

    private func push(_ entry: Delegation.Entry, client: ServerClient) async -> String? {
        let request: AdoptRequest
        switch entry.kind {
        case .apiKey:
            guard let key = (try? APIKeyStore.read(entry.id)) ?? nil, !key.isEmpty else {
                return nil
            }
            request = AdoptRequest(apiKey: key, label: entry.displayName)
        case .subscription:
            guard let credential = vault.credential(for: entry.id),
                  credential.refreshToken?.isEmpty == false else { return nil }
            request = AdoptRequest(credentialJSON: credential.jsonString(),
                                   label: entry.displayName)
        }
        if let adopted = try? await client.adopt(request) { return adopted.id }
        // The adopt may well have succeeded and only its answer been lost — the client
        // gives up at 20s and the server can take longer. Assuming failure is the one
        // reading that leaves both sides holding the lineage, so the server is asked
        // what it actually has before that conclusion is drawn.
        return await alreadyOnServer(entry, client: client)
    }

    /// Whether the server holds this account after all, matched the same way the planner
    /// matches: by account UUID for a subscription, by key fingerprint for an API key.
    private func alreadyOnServer(_ entry: Delegation.Entry,
                                 client: ServerClient) async -> String? {
        guard let remote = try? await client.accounts() else { return nil }
        switch entry.kind {
        case .subscription:
            return remote.first { $0.id == entry.id && $0.kind == .subscription }?.id
        case .apiKey:
            guard let key = (try? APIKeyStore.read(entry.id)) ?? nil, !key.isEmpty else {
                return nil
            }
            let fingerprint = key.apiKeyFingerprint
            return remote.first { $0.apiKeyFingerprint == fingerprint && $0.kind == .apiKey }?.id
        }
    }

    private func importAccount(_ remote: RemoteAccount, client: ServerClient,
                               delegated: inout Set<String>) async -> Bool {
        adoptRemoteRecord(remote)
        return await handOver(remote.id, localID: remote.id, client: client,
                              delegated: &delegated)
    }

    /// Mirrors the server's metadata into a local account record, creating one if needed.
    /// Carries no credential — that is `handOver`'s job.
    private func adoptRemoteRecord(_ remote: RemoteAccount) {
        var account = store.accounts.get(remote.id)
            ?? Account(id: remote.id, label: remote.label, kind: remote.kind)
        account.label = remote.label
        account.email = remote.email
        account.organizationUUID = remote.organizationUUID
        account.organizationName = remote.organizationName
        account.subscriptionType = remote.subscriptionType
        account.rateLimitTier = remote.rateLimitTier
        account.kind = remote.kind
        account.health = remote.health
        account.healthDetail = remote.healthDetail
        if account.priority == 0 {
            account.priority = (store.accounts.all().map(\.priority).max() ?? 0) + 1
        }
        store.accounts.upsert(account)
    }

    /// An API-key account's id is generated by whichever Mac added it. When the server
    /// already knows the same key under a different id, the local record moves rather than
    /// becoming a duplicate.
    private func renumberAPIKeyAccount(from oldID: String, to newID: String) {
        guard var account = store.accounts.get(oldID), store.accounts.get(newID) == nil else {
            return
        }
        account.id = newID
        store.accounts.upsert(account)
        store.removeAccount(oldID)
        try? APIKeyStore.delete(oldID)
    }

    // MARK: - Login through the relay

    /// Signs a delegated account in again. The browser runs here, but the PKCE verifier
    /// and the code exchange are the server's, so the refresh token is born there and
    /// this Mac never holds one.
    func beginServerLogin(accountID: String?, chromeProfileDirectory: String?,
                          loginHint: String?) async {
        guard let client = serverClient else {
            // The button is the only affordance for a delegated account that needs
            // signing in again; returning quietly makes it look broken.
            banner = Banner(level: .warning,
                            text: settings.server == nil
                                ? "This account is delegated but no account server is "
                                    + "configured. Connect one in Settings."
                                : "Could not reach the account server's saved password in "
                                    + "the Keychain. Reconnect it in Settings.")
            return
        }
        guard !loginInProgress else { return }
        loginInProgress = true
        defer { loginInProgress = false }

        let listener: LoopbackListener
        do {
            listener = try LoopbackListener()
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
            return
        }
        defer { listener.stop() }

        do {
            let started = try await client.startLogin(
                LoginStartRequest(redirectPort: listener.port, accountID: accountID,
                                  loginHint: loginHint))
            let outcome = ChromeLauncher.open(url: started.authorizeURL,
                                              profileDirectory: chromeProfileDirectory)
            banner = Banner(level: .info,
                            text: "Waiting for sign-in… \(outcome.message)")

            let items = try await listener.awaitCallback(timeout: 300)
            guard let code = items["code"] else {
                banner = Banner(level: .warning, text: "The browser returned no code.")
                return
            }
            guard items["state"] == nil || items["state"] == started.state else {
                banner = Banner(level: .warning,
                                text: "Sign-in state did not match; nothing was stored.")
                return
            }
            let account = try await client.finishLogin(
                LoginFinishRequest(loginID: started.loginID, code: code,
                                   state: items["state"]))

            var delegated = settings.delegated
            _ = await importAccount(account, client: client, delegated: &delegated)
            commitDelegation(delegated, client: client)
            banner = Banner(level: .info, text: "Signed in as \(account.displayName).")
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
        }
    }

    // MARK: - Usage

    /// Usage for delegated accounts comes from the server's cache. One poller per account
    /// instead of one per Mac: the endpoint budgets ~28 requests an hour per token, and
    /// two Macs polling the same account independently would spend it twice over for the
    /// same numbers.
    func pollDelegatedUsage() async {
        guard let client = serverClient else { return }
        let now = Date()
        for accountID in settings.delegatedAccountIDs {
            guard store.accounts.get(accountID)?.kind == .subscription else { continue }
            // The housekeeping tick is every 20s, which is far more often than these
            // numbers move. `serveTTL` is the same floor the app already applies to a
            // locally held snapshot.
            if let fetched = store.usage(for: accountID)?.fetchedAt,
               now.timeIntervalSince(fetched) < PollPolicy.serveTTL { continue }
            guard let remote = try? await client.usage(for: accountID),
                  !remote.windows.isEmpty else { continue }
            // Dated by the server's own age, not by when it arrived here. Stamping it now
            // would let a rate-limited server's 20-minute-old numbers look current, and
            // ranking would keep choosing an account that is already exhausted.
            record(.success(remote.windows), for: accountID,
                   fetchedAt: Date().addingTimeInterval(-max(0, remote.ageSeconds)))
        }
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
