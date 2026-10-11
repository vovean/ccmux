import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Server URL")
struct ServerURLTests {
    @Test func aBareHostGetsHTTPSAndTheDefaultPort() {
        let url = Engine.normalizeServerURL("ccmux.example.com")
        #expect(url?.absoluteString == "https://ccmux.example.com:8443")
    }

    /// Both spellings have to work — the design requires reaching one server by name and
    /// by address, because a self-signed certificate carries both SANs.
    @Test func aRawIPWorksTheSameWay() {
        #expect(Engine.normalizeServerURL("203.0.113.10")?.absoluteString
                == "https://203.0.113.10:8443")
        #expect(Engine.normalizeServerURL("https://203.0.113.10:9000")?.absoluteString
                == "https://203.0.113.10:9000")
    }

    /// A trailing path would be doubled by `appendingPathComponent` and every request
    /// would 404.
    @Test func aTrailingPathIsDropped() {
        #expect(Engine.normalizeServerURL("https://host:8443/v1/")?.absoluteString
                == "https://host:8443")
        #expect(Engine.normalizeServerURL("https://host:8443/?x=1")?.absoluteString
                == "https://host:8443")
    }

    @Test func rubbishIsRejected() {
        #expect(Engine.normalizeServerURL("") == nil)
        #expect(Engine.normalizeServerURL("   ") == nil)
        #expect(Engine.normalizeServerURL("https://") == nil)
    }

    /// settings.json is plaintext on disk and is the one place the design keeps the
    /// password out of — but pasting https://user:pass@host into an address field is a
    /// natural thing to try, and the string is stored verbatim.
    @Test func embeddedCredentialsAreStripped() {
        let url = Engine.normalizeServerURL("https://ccmux:hunter2@ccmux.example.com:8443")
        #expect(url?.absoluteString == "https://ccmux.example.com:8443")
        #expect(url?.absoluteString.contains("hunter2") == false)
    }
}

@Suite("Fingerprint display")
struct FingerprintTests {
    @Test func itIsGroupedForReadingAloud() {
        let hex = String(repeating: "ab", count: 32)
        let shown = ServerFingerprint.display(hex)
        #expect(shown.hasPrefix("AB:AB:AB"))
        #expect(shown.split(separator: ":").count == 32)
    }

    @Test func theShortFormIsTruncated() {
        let short = ServerFingerprint.short(String(repeating: "cd", count: 32))
        #expect(short == "CD:CD:CD:CD:CD:CD…")
    }
}

@Suite("Grant usability")
struct GrantUsabilityTests {
    /// The credential-loss path this closes: the server returns whatever it holds even
    /// when its own refresh failed, so a grant can carry a token that expired minutes ago.
    /// Handing over on one of those overwrites the Mac's working refresh token with a dead
    /// access token, and the account is unrecoverable without a browser re-login.
    @Test func anExpiredGrantIsNotUsable() {
        let dead = TokenGrant(accountID: "a", kind: .subscription, accessToken: "stale",
                              expiresIn: 0)
        #expect(!dead.isUsable)
        #expect(!TokenGrant(accountID: "a", kind: .subscription, accessToken: "stale",
                            expiresIn: -30).isUsable)
    }

    @Test func aLiveGrantIsUsable() {
        #expect(TokenGrant(accountID: "a", kind: .subscription, accessToken: "fresh",
                           expiresIn: 3600).isUsable)
    }

    /// A server that did not state an expiry leaves the question to normal expiry
    /// handling rather than to this check.
    @Test func anUnstatedExpiryIsAccepted() {
        #expect(TokenGrant(accountID: "a", kind: .subscription, accessToken: "t").isUsable)
    }

    @Test func aGrantWithNoTokenAtAllIsNotUsable() {
        #expect(!TokenGrant(accountID: "a", kind: .subscription, expiresIn: 3600).isUsable)
        #expect(!TokenGrant(accountID: "a", kind: .subscription, accessToken: "",
                            expiresIn: 3600).isUsable)
    }

    /// An API key has no expiry — only presence matters.
    @Test func anAPIKeyGrantOnlyNeedsAKey() {
        #expect(TokenGrant(accountID: "a", kind: .apiKey, apiKey: "sk-ant-x").isUsable)
        #expect(!TokenGrant(accountID: "a", kind: .apiKey).isUsable)
        #expect(!TokenGrant(accountID: "a", kind: .apiKey, apiKey: "").isUsable)
    }
}
