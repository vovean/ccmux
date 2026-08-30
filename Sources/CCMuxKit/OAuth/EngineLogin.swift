import CCMuxCore
import Foundation

/// Everything needed to redeem a code, reopen the browser, or start over.
///
/// Held on the engine rather than captured in the login task, because the modal has to be
/// able to act on an attempt the task is currently blocked inside.
struct LoginContext {
    var port: UInt16
    /// Local sign-in: this Mac redeems the code, so it holds the verifier.
    var pkce: OAuthClient.PKCE?
    /// Relayed sign-in: ccmuxd holds the verifier and redeems the code, so the refresh
    /// token is born there and never touches this Mac.
    var loginID: String?
    var state: String
    var chromeProfileDirectory: String?
    var loginHint: String?
    var label: String?
    var accountID: String?
    var throughServer: Bool
}

public extension Engine {
    /// Opens the browser and arms the loopback listener, then returns immediately.
    ///
    /// The wait happens in a task the modal can cancel, which is the whole point: the old
    /// flow blocked for five minutes inside one `await`, so closing the browser left a
    /// disabled button and no way back.
    func startLogin(accountID: String? = nil, label: String? = nil,
                    loginHint: String? = nil, chromeProfileDirectory: String? = nil) async {
        cancelLogin()

        let delegated = accountID.map { settings.delegated.contains($0) } ?? false
        let listener: LoopbackListener
        do {
            listener = try LoopbackListener()
        } catch {
            banner = Banner(level: .warning, text: error.localizedDescription)
            return
        }
        // Registered before the first suspension point, not after it. `cancelLogin` can
        // only reach what is on the engine, so a listener still living in a local while
        // ccmuxd is answering is one a second click cannot stop — it would sit on a bound
        // loopback socket for the full timeout and later redeem against another attempt's
        // context.
        let generation = UUID()
        loginGeneration = generation
        loginListener = listener

        var context = LoginContext(port: listener.port, state: "",
                                   chromeProfileDirectory: chromeProfileDirectory,
                                   loginHint: loginHint, label: label,
                                   accountID: accountID, throughServer: delegated)
        let authorizeURL: String

        if delegated {
            guard let client = serverClient else {
                listener.stop()
                banner = Banner(level: .warning,
                                text: settings.server == nil
                                    ? "This account is delegated but no account server is "
                                        + "configured. Connect one in Settings."
                                    : "Could not reach the account server's saved password "
                                        + "in the Keychain. Reconnect it in Settings.")
                return
            }
            do {
                let started = try await client.startLogin(
                    LoginStartRequest(redirectPort: listener.port, accountID: accountID,
                                      loginHint: loginHint))
                // Superseded while ccmuxd was answering: this attempt's listener must go,
                // and nothing of it may be written over the one that replaced it.
                guard loginGeneration == generation else {
                    listener.stop()
                    return
                }
                context.loginID = started.loginID
                context.state = started.state
                authorizeURL = started.authorizeURL
            } catch {
                if loginGeneration == generation { cancelLogin() } else { listener.stop() }
                banner = Banner(level: .warning, text: error.localizedDescription)
                return
            }
        } else {
            let pkce = OAuthClient.PKCE()
            context.pkce = pkce
            context.state = pkce.state
            authorizeURL = OAuthClient.authorizeURL(pkce: pkce, port: listener.port,
                                                    email: loginHint).absoluteString
        }

        loginContext = context
        loginAttempt = LoginAttempt(id: generation,
                                    target: target(for: accountID, label: label),
                                    authorizeURL: authorizeURL, throughServer: delegated)
        // 6: a browser that never opened must not look like one that did. When Chrome is
        // missing the launcher puts the URL on the clipboard, and saying so is the
        // difference between a 15-minute wait and a paste.
        let outcome = ChromeLauncher.open(url: authorizeURL,
                                          profileDirectory: chromeProfileDirectory)
        loginAttempt?.launchNote = outcome.opened ? nil : outcome.message
        loginTask = Task { [weak self] in await self?.runLogin(listener, generation) }
    }

    private func target(for accountID: String?, label: String?) -> LoginAttempt.Target {
        guard let accountID else { return .newAccount(label: label) }
        return .existing(accountID: accountID,
                         name: store.accounts.get(accountID)?.displayName ?? accountID)
    }

    /// Listens for as long as the modal is open.
    ///
    /// Deliberately a loop, and deliberately never stops the socket on a failure. A
    /// rejected code — a verification code typed in the wrong box, an expired one, a
    /// server that said no — used to take the listener down with it, so the callback the
    /// browser delivered afterwards hit a closed port and the sign-in could not finish
    /// without starting over. The only things that end this are success, cancel, and
    /// Start over.
    private func runLogin(_ listener: LoopbackListener, _ generation: UUID) async {
        while loginGeneration == generation {
            do {
                let items = try await listener.awaitCallback(timeout: 900)
                // An empty value is not a code: `OAuthClient.exchange` splits on "#" with
                // empty subsequences dropped, so "" indexes an empty array and traps.
                guard let code = items["code"], !code.isEmpty else {
                    report(.failed("The browser came back without a code."), generation)
                    continue
                }
                await redeem(code: code, state: items["state"], generation: generation)
                if loginAttempt?.isSucceeded == true { return }
            } catch LoopbackError.cancelled {
                return
            } catch {
                report(.failed(error.localizedDescription), generation)
                return
            }
        }
    }

    /// Redeems the code, here or on the server depending on who owns the lineage.
    private func redeem(code: String, state: String?, generation: UUID) async {
        guard loginGeneration == generation, let context = loginContext else { return }
        // A mismatched state means the code belongs to a different sign-in; redeeming it
        // would attach the wrong account.
        guard state == nil || state == context.state else {
            report(.failed("Sign-in state did not match; nothing was stored."),
                        generation)
            return
        }
        // One redemption at a time: the browser can land while a pasted code is still in
        // flight, and two exchanges against one verifier means the loser is told
        // `invalid_grant` while the winner has already stored a credential.
        guard !redeemingLogin else { return }
        redeemingLogin = true
        defer { redeemingLogin = false }
        loginAttempt?.phase = .exchanging

        do {
            let name: String
            if context.throughServer {
                guard let client = serverClient, let loginID = context.loginID else {
                    report(.failed("The account server is no longer reachable."),
                                generation)
                    return
                }
                let account = try await client.finishLogin(
                    LoginFinishRequest(loginID: loginID, code: code, state: state))
                var delegated = settings.delegated
                _ = await importAccount(account, client: client, delegated: &delegated)
                commitDelegation(delegated, client: client)
                name = account.displayName
            } else {
                guard let pkce = context.pkce else {
                    report(.failed("This sign-in has expired. Start it again."),
                                generation)
                    return
                }
                let credential = try await client.exchange(code: code, pkce: pkce,
                                                           port: context.port)
                let account = try await adopt(
                    credential: credential,
                    chromeProfileDirectory: context.chromeProfileDirectory,
                    label: context.label)
                name = account.displayName
            }
            report(.succeeded(name), generation)
            banner = Banner(level: .info, text: "Signed in as \(name).")
        } catch {
            report(.failed(error.localizedDescription), generation)
        }
    }

    /// Writes a result back only if this attempt is still the one on screen. A redeem the
    /// user abandoned can otherwise land minutes later and mark its successor failed —
    /// or, worse, tell them a different sign-in succeeded.
    ///
    /// Only success takes the listener down. Leaving it armed through a failure is what
    /// lets a mistyped code be followed by the real callback without starting over.
    private func report(_ phase: LoginAttempt.Phase, _ generation: UUID) {
        guard loginGeneration == generation else { return }
        loginAttempt?.phase = phase
        if case .succeeded = phase {
            loginListener?.stop()
            loginListener = nil
        }
    }

    // MARK: - What the modal drives

    /// Redeems a code the user pasted, without disturbing the listener.
    ///
    /// The browser is still expected to come back; a paste is an additional route to the
    /// same sign-in, not a replacement for it.
    func submitLoginCode(_ raw: String) {
        guard let attempt = loginAttempt, attempt.acceptsCode,
              let generation = loginGeneration else { return }
        // The six digits on the authorize page are not an authorization code — they are
        // typed into that page to prove it is the same person. Sending one here spends a
        // round trip to be told it is invalid, and it is a mistake the page's own wording
        // invites, so it is named rather than merely rejected.
        if LoginCode.looksLikeVerificationCode(raw) {
            loginAttempt?.pasteError =
                "That is the browser's verification code. Type it into the page in your "
                + "browser — this box wants the sign-in code you get afterwards."
            return
        }
        guard let parsed = LoginCode.parse(raw) else {
            // Reported without touching the phase: a rejected paste must not make the
            // attempt look finished while its listener is still armed.
            loginAttempt?.pasteError = "That does not look like a sign-in code."
            return
        }
        loginAttempt?.pasteError = nil
        Task { [weak self] in
            await self?.redeem(code: parsed.code, state: parsed.state,
                               generation: generation)
        }
    }

    /// Throws the attempt away. Closing the modal lands here, so the Sign in button is
    /// live again immediately rather than after a timeout.
    func cancelLogin() {
        loginGeneration = nil
        loginTask?.cancel()
        loginTask = nil
        loginListener?.stop()
        loginListener = nil
        loginContext = nil
        loginAttempt = nil
    }

    /// Starts over on a fresh port with a fresh PKCE pair, reusing what the user already
    /// told us about which account and which browser profile.
    func restartLogin() {
        guard let context = loginContext else { return }
        Task {
            await startLogin(accountID: context.accountID, label: context.label,
                             loginHint: context.loginHint,
                             chromeProfileDirectory: context.chromeProfileDirectory)
        }
    }

    func reopenLoginBrowser() {
        guard let attempt = loginAttempt else { return }
        let outcome = ChromeLauncher.open(url: attempt.authorizeURL,
                                          profileDirectory: loginContext?.chromeProfileDirectory)
        loginAttempt?.launchNote = outcome.opened ? nil : outcome.message
    }
}
