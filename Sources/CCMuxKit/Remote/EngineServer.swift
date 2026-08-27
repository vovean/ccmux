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
                                  password: password, fingerprint: connection.fingerprint)
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
            return .success(try await ServerClient.probeFingerprint(baseURL: url))
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
                                  fingerprint: fingerprint)
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
                if await handOver(remoteID, localID: entry.id, client: client,
                                  delegated: &delegated) {
                    pushed += 1
                } else {
                    problems.append(entry.displayName)
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

        updateSettings { $0.delegatedAccountIDs = delegated.sorted() }
        applyRemoteToVault()
        delegationPlan = nil

        var parts: [String] = []
        if took > 0 { parts.append("\(took) delegated") }
        if pushed > 0 { parts.append("\(pushed) pushed up") }
        if imported > 0 { parts.append("\(imported) imported") }
        let summary = parts.isEmpty ? "Nothing changed" : parts.joined(separator: ", ")
        banner = problems.isEmpty
            ? Banner(level: .info, text: summary + ".")
            : Banner(level: .warning,
                     text: summary + ". Left alone: " + problems.joined(separator: ", ")
                         + " — they still work from this Mac.")
    }

    /// Mint, then delete. Asking the server for a token first is what makes this safe: a
    /// server that holds the account but whose own lineage is dead would otherwise leave
    /// the account with no working credential on either side.
    private func handOver(_ remoteID: String, localID: String, client: ServerClient,
                          delegated: inout Set<String>) async -> Bool {
        guard let grant = try? await client.grant(for: remoteID) else { return false }

        if remoteID != localID {
            // Only an API-key account can differ, and its local id is meaningless. Move
            // the record onto the server's id so one id identifies it everywhere.
            renumberAPIKeyAccount(from: localID, to: remoteID)
        }
        delegated.insert(remoteID)
        // Set before storing: the vault must know not to attempt a local refresh grant on
        // a credential that no longer carries a refresh token.
        vault.setRemote(client, delegated: delegated)

        switch grant.kind {
        case .apiKey:
            guard let key = grant.apiKey, !key.isEmpty else { return false }
            try? APIKeyStore.write(key, for: remoteID)
        case .subscription:
            guard let credential = grant.credential() else { return false }
            // Overwrites the local credential, which is how the local refresh token stops
            // existing. The lineage it belonged to is simply never refreshed again and
            // expires on its own — harmless, because lineages are independent.
            vault.store(credential, for: remoteID)
            sessionManager.reseedNamespaces(accountID: remoteID, credential: credential)
        }
        store.accounts.mutate(remoteID) { $0.health = .ok; $0.healthDetail = nil }
        return true
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
        return try? await client.adopt(request).id
    }

    private func importAccount(_ remote: RemoteAccount, client: ServerClient,
                               delegated: inout Set<String>) async -> Bool {
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
        return await handOver(remote.id, localID: remote.id, client: client,
                              delegated: &delegated)
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
        guard let client = serverClient else { return }
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
            updateSettings { $0.delegatedAccountIDs = delegated.sorted() }
            applyRemoteToVault()
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
            record(.success(remote.windows), for: accountID)
        }
    }

    nonisolated static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host,
              !host.isEmpty else { return nil }
        if components.port == nil { components.port = 8443 }
        // Trailing path would end up doubled by appendingPathComponent.
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
