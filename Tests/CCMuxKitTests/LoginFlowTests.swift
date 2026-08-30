import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Pasting a sign-in code")
struct LoginCodeTests {
    /// What the authorize page shows when it cannot hand the code back directly.
    @Test func theCodeHashStateFormSplits() {
        let parsed = LoginCode.parse("abc123#state-xyz")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "state-xyz")
    }

    @Test func aBareCodeCarriesNoState() {
        let parsed = LoginCode.parse("abc123")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == nil)
    }

    /// People paste the whole address bar at least as often as the code, and the callback
    /// URL is right there in front of them when the loopback fails.
    @Test func awholeCallbackURLIsAccepted() {
        let parsed = LoginCode.parse(
            "http://localhost:51234/callback?code=abc123&state=state-xyz")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "state-xyz")
    }

    @Test func aCallbackThatLostItsSchemeStillWorks() {
        let parsed = LoginCode.parse("localhost:51234/callback?code=abc123#state-xyz")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "state-xyz")
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(LoginCode.parse("  abc123#st  ")?.code == "abc123")
        #expect(LoginCode.parse("  abc123#st  ")?.state == "st")
    }

    /// A callback pasted without its scheme, with the parameters in the order the server
    /// happened to emit them. Scanning for a literal "?code=" only ever matched when the
    /// code came first, and returned the entire string as the code when it did not.
    @Test func codeIsFoundWhateverOrderTheParametersArrivedIn() {
        let parsed = LoginCode.parse("localhost:51234/callback?state=xyz&code=abc123")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "xyz")
    }

    @Test func justTheQueryPairsAreEnough() {
        #expect(LoginCode.parse("code=abc123&state=xyz")?.code == "abc123")
        #expect(LoginCode.parse("code=abc123&state=xyz")?.state == "xyz")
    }

    /// A state in the fragment of a full URL was dropped, and `redeem` accepts a nil
    /// state — so the check silently did not happen.
    @Test func aStateInTheFragmentOfAFullURLSurvives() {
        let parsed = LoginCode.parse("http://localhost:51234/callback?code=abc123#state-xyz")
        #expect(parsed?.code == "abc123")
        #expect(parsed?.state == "state-xyz")
    }

    /// A paste we did not understand must be refused rather than sent to the token
    /// endpoint to come back as an opaque 400.
    @Test func punctuationWeCannotParseIsRefused() {
        #expect(LoginCode.parse("localhost:51234/callback") == nil)
        #expect(LoginCode.parse("a&b") == nil)
    }

    /// The exact paste that broke a real sign-in: the six digits from the authorize page
    /// went to the token endpoint as if they were an authorization code, and the failure
    /// took the loopback listener down with it — so the callback the browser delivered a
    /// minute later hit a closed port.
    @Test func theBrowsersVerificationCodeIsRecognisedNotRedeemed() {
        #expect(LoginCode.looksLikeVerificationCode("596123"))
        #expect(LoginCode.looksLikeVerificationCode(" 596123 "))
        #expect(LoginCode.looksLikeVerificationCode("12345678"))

        // A real authorization code is long and not all digits.
        #expect(!LoginCode.looksLikeVerificationCode(
            "Kp7wQx2mN4vRt9bZ3sLdYf6HjCg8AeUi5oTn1XyMkWqB"))
        #expect(!LoginCode.looksLikeVerificationCode("abc123"))
        #expect(!LoginCode.looksLikeVerificationCode(""))
        #expect(!LoginCode.looksLikeVerificationCode("123"))
    }

    /// The callback that was refused, parsed as it actually arrives.
    @Test func theRealCallbackFromThatSignInParses() {
        let parsed = LoginCode.parse(
            "http://localhost:51234/callback?code=Kp7wQx2mN4vRt9bZ3sLdYf6HjCg8AeUi5oTn"
            + "1XyMkWqB&state=7Qm2pR_xVdA_41Nz_kLbShTfWoY9E-2CJreuMK_ZgpN")
        #expect(parsed?.code == "Kp7wQx2mN4vRt9bZ3sLdYf6HjCg8AeUi5oTn1XyMkWqB")
        #expect(parsed?.state == "7Qm2pR_xVdA_41Nz_kLbShTfWoY9E-2CJreuMK_ZgpN")
    }

    /// Nothing usable must not be reported as a code — redeeming an empty string spends a
    /// round trip to be told the obvious.
    @Test func nothingUsableIsRejected() {
        #expect(LoginCode.parse("") == nil)
        #expect(LoginCode.parse("   ") == nil)
        #expect(LoginCode.parse("#only-state") == nil)
        #expect(LoginCode.parse("http://localhost:1/callback?state=x") == nil)
    }
}

@Suite("What the login modal offers")
struct LoginAttemptTests {
    private func attempt(_ phase: LoginAttempt.Phase) -> LoginAttempt {
        LoginAttempt(target: .newAccount(label: nil), phase: phase,
                     authorizeURL: "https://claude.com/cai/oauth/authorize?x=1",
                     throughServer: false)
    }

    /// The paste box stays available after a failure on purpose: a loopback that did not
    /// come back is the single likeliest reason to be pasting at all.
    @Test func aCodeCanStillBePastedAfterAFailure() {
        #expect(attempt(.waiting).acceptsCode)
        #expect(attempt(.failed("boom")).acceptsCode)
        #expect(!attempt(.exchanging).acceptsCode)
        #expect(!attempt(.succeeded("someone")).acceptsCode)
    }

    /// Pattern-matched rather than compared against a value: `.succeeded("")` never
    /// equals `.succeeded("someone")`, so an equality test here silently never fires.
    @Test func successIsRecognisedWhateverTheNameIs() {
        #expect(attempt(.succeeded("someone")).isSucceeded)
        #expect(attempt(.succeeded("")).isSucceeded)
        #expect(!attempt(.waiting).isSucceeded)
        #expect(!attempt(.failed("boom")).isSucceeded)
    }

    /// A refused paste must not touch the phase: while the listener is still armed an
    /// attempt that looks finished would let the next paste start a second redeemer
    /// against the same authorize request.
    @Test func aRejectedPasteIsReportedWithoutEndingTheAttempt() {
        var live = attempt(.waiting)
        live.pasteError = "That does not look like a sign-in code."
        #expect(live.phase == .waiting)
        #expect(live.acceptsCode)
        #expect(live.isBusy)
    }

    /// The browser not opening has to be visible — the URL goes to the clipboard, and
    /// without saying so the modal just waits on a window that never appeared.
    @Test func aBrowserThatDidNotOpenIsCarriedOnTheAttempt() {
        #expect(OpenOutcome.openedInDefaultBrowser.opened)
        #expect(OpenOutcome.openedInProfile("Default").opened)
        #expect(!OpenOutcome.copiedToClipboard(reason: "Google Chrome not found").opened)

        var stranded = attempt(.waiting)
        stranded.launchNote = OpenOutcome
            .copiedToClipboard(reason: "Google Chrome not found").message
        #expect(stranded.launchNote?.contains("copied") == true)
    }

    /// Every login mutation is keyed on the attempt id, so a redeem the user walked away
    /// from cannot write its result over the attempt that replaced it.
    @Test func attemptsAreDistinguishableAcrossARestart() {
        let first = attempt(.waiting)
        let second = attempt(.waiting)
        #expect(first.id != second.id)
    }

    @Test func onlyAnUnfinishedAttemptIsBusy() {
        #expect(attempt(.waiting).isBusy)
        #expect(attempt(.exchanging).isBusy)
        #expect(!attempt(.failed("boom")).isBusy)
        #expect(!attempt(.succeeded("someone")).isBusy)
    }

    /// A relogin must name the account, so it cannot be mistaken for adding a stranger.
    @Test func anExistingAccountIsNamedInTheTitle() {
        let relogin = LoginAttempt(target: .existing(accountID: "acct-1", name: "Work"),
                                   authorizeURL: "https://example.com", throughServer: true)
        #expect(relogin.title == "Sign in to Work")
        #expect(relogin.accountID == "acct-1")

        let fresh = attempt(.waiting)
        #expect(fresh.title == "Add a subscription")
        #expect(fresh.accountID == nil)
    }
}

@Suite("A record that lost its kind")
struct AccountKindRepairTests {
    /// The exact corruption found in the wild: an API-key account recorded as a
    /// subscription in rotation, with its key still in the Keychain.
    @Test func aStoredKeyOutranksTheRecord() {
        var account = Account(id: "2282AD3F", label: "ct1 key")
        #expect(account.kind == .subscription)
        #expect(account.inRotation)
        // Auto-assignable means the policy engine can spend money on it unprompted.
        #expect(account.isAutoAssignable)
        #expect(account.contradictsStoredAPIKey(hasStoredAPIKey: true))

        account.kind = .apiKey
        account.inRotation = false
        #expect(!account.isAutoAssignable)
        #expect(!account.contradictsStoredAPIKey(hasStoredAPIKey: true))
    }

    /// A subscription with no key in the Keychain is not evidence of anything, and must
    /// be left exactly as it is.
    @Test func asubscriptionWithNoKeyIsLeftAlone() {
        let account = Account(id: "acct-1", label: "Work")
        #expect(!account.contradictsStoredAPIKey(hasStoredAPIKey: false))
    }

    /// The decoder defaults that cause it, pinned so the behaviour is not a surprise.
    @Test func aMissingKindDecodesAsAnInRotationSubscription() throws {
        let json = Data(#"{"id":"x","label":"ct1 key","priority":4,"health":"ok"}"#.utf8)
        let decoded = try JSONStore.decoder.decode(Account.self, from: json)
        #expect(decoded.kind == .subscription)
        #expect(decoded.inRotation)
        #expect(decoded.contradictsStoredAPIKey(hasStoredAPIKey: true))
    }
}

@Suite("The loopback listener outlives a failure")
struct LoopbackReuseTests {
    private func deliver(port: UInt16, query: String) async {
        let url = URL(string: "http://127.0.0.1:\(port)/callback?\(query)")!
        _ = try? await URLSession.shared.data(from: url)
    }

    /// The whole point of keeping the listener armed: a code that is rejected must not
    /// deafen ccmux to the callback the browser delivers afterwards. That only works if
    /// one listener can serve more than one callback, so it is pinned rather than assumed.
    @Test func oneListenerServesASecondCallback() async throws {
        let listener = try LoopbackListener()
        defer { listener.stop() }

        async let first = listener.awaitCallback(timeout: 10)
        await deliver(port: listener.port, query: "code=first&state=s1")
        let one = try await first
        #expect(one["code"] == "first")

        // The socket is still bound, so the browser coming back later still lands.
        async let second = listener.awaitCallback(timeout: 10)
        await deliver(port: listener.port, query: "code=second&state=s2")
        let two = try await second
        #expect(two["code"] == "second")
        #expect(two["state"] == "s2")
    }

    /// And stopping it really does end the wait — cancel and Start over depend on it.
    @Test func stoppingEndsTheWait() async throws {
        let listener = try LoopbackListener()
        let waiting = Task { try await listener.awaitCallback(timeout: 10) }
        listener.stop()
        var threw = false
        do { _ = try await waiting.value } catch { threw = true }
        #expect(threw)
    }
}
