import Foundation
import Testing
@testable import CCMuxKit

@Suite("Claude Code credential interop")
struct CredentialTests {
    /// The namespaced service name is how Claude Code finds a session's credential.
    /// Getting it wrong presents as "Not logged in", so it is pinned to values
    /// computed independently of this implementation.
    @Test func namespaceServiceNameMatchesClaudeCode() {
        #expect(ClaudeCredentialStore.service(forNamespace: URL(fileURLWithPath: "/tmp/ccmux-test-ns"))
                == "Claude Code-credentials-eecacb8e")
        #expect(ClaudeCredentialStore.service(forNamespace: URL(fileURLWithPath: "/Users/example/.claude"))
                == "Claude Code-credentials-402b469b")
    }

    @Test func globalServiceNameHasNoSuffix() {
        #expect(ClaudeCredentialStore.globalService == "Claude Code-credentials")
    }

    @Test func credentialRoundTripsThroughClaudeCodeShape() throws {
        let raw = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def",\
        "expiresAt":1787365672163,"refreshTokenExpiresAt":1789866145163,\
        "scopes":["user:inference","user:profile"],"subscriptionType":"team",\
        "rateLimitTier":"default_claude_max_5x"}}
        """
        let credential = try #require(OAuthCredential(json: raw))
        #expect(credential.accessToken == "sk-ant-oat01-abc")
        #expect(credential.refreshToken == "sk-ant-ort01-def")
        #expect(credential.subscriptionType == "team")
        #expect(credential.rateLimitTier == "default_claude_max_5x")
        #expect(credential.scopes == ["user:inference", "user:profile"])
        #expect(Int(credential.expiresAt!.timeIntervalSince1970 * 1000) == 1787365672163)

        let reparsed = try #require(OAuthCredential(json: credential.jsonString()))
        #expect(reparsed == credential)
    }

    /// A newer Claude Code adding a field must not lose it when we seed a namespace.
    @Test func unknownCredentialKeysSurvive() throws {
        let raw = """
        {"claudeAiOauth":{"accessToken":"tok","expiresAt":1787365672163,\
        "somethingNew":{"nested":true},"futureCount":7}}
        """
        let credential = try #require(OAuthCredential(json: raw))
        let written = credential.jsonString()
        #expect(written.contains("somethingNew"))
        #expect(written.contains("futureCount"))

        let object = try JSONSerialization.jsonObject(with: Data(written.utf8))
        let oauth = (object as? [String: Any])?["claudeAiOauth"] as? [String: Any]
        #expect(((oauth?["somethingNew"] as? [String: Any])?["nested"] as? Bool) == true)
        #expect((oauth?["futureCount"] as? Double) == 7)
    }

    @Test func missingAccessTokenIsNotACredential() {
        #expect(OAuthCredential(json: #"{"claudeAiOauth":{"refreshToken":"x"}}"#) == nil)
        #expect(OAuthCredential(json: #"{"claudeAiOauth":{"accessToken":""}}"#) == nil)
        #expect(OAuthCredential(json: "not json") == nil)
    }

    @Test func expiryUsesClaudeCodesFiveMinuteBuffer() {
        let almost = OAuthCredential(accessToken: "t", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(120))
        #expect(almost.isAccessTokenExpired)

        let fine = OAuthCredential(accessToken: "t", refreshToken: nil,
                                   expiresAt: Date().addingTimeInterval(3600))
        #expect(!fine.isAccessTokenExpired)

        let unknown = OAuthCredential(accessToken: "t", refreshToken: nil, expiresAt: nil)
        #expect(!unknown.isAccessTokenExpired)
    }

    @Test func keychainServiceNamesAreQuotedForSecurityStdin() {
        #expect(Keychain.quote("Claude Code-credentials") == "\"Claude Code-credentials\"")
        #expect(Keychain.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}

@Suite("Seeded session credentials")
struct SeededCredentialTests {
    /// The load-bearing property: a session's Claude Code must not be able to rotate the
    /// lineage, because whichever refresher lost that race would be logged out for good.
    @Test func seededCredentialCannotBeRefreshed() {
        let live = OAuthCredential(accessToken: "sk-ant-oat01-live",
                                   refreshToken: "sk-ant-ort01-secret",
                                   expiresAt: Date().addingTimeInterval(3600),
                                   refreshTokenExpiresAt: Date().addingTimeInterval(86400),
                                   scopes: ["user:inference"], subscriptionType: "max")
        let seeded = live.neuteredForSession()

        #expect(seeded.refreshToken == nil)
        #expect(seeded.refreshTokenExpiresAt == nil)
        #expect(seeded.accessToken == live.accessToken)
        // Everything else is carried through so Claude Code reads the same account.
        #expect(seeded.scopes == live.scopes)
        #expect(seeded.subscriptionType == "max")
    }

    /// And it must not look like it needs refreshing either, or Claude Code would try
    /// and hard-fail with no refresh token to try it with.
    @Test func seededCredentialLooksFreshForAYear() throws {
        let seeded = OAuthCredential(accessToken: "t", refreshToken: "r",
                                     expiresAt: Date().addingTimeInterval(60))
            .neuteredForSession()
        #expect(!seeded.isAccessTokenExpired)
        let expiry = try #require(seeded.expiresAt)
        #expect(expiry.timeIntervalSinceNow > 300 * 86400)
    }

    /// The refresh token has to survive in ccmux's own copy — only the seeded one is
    /// stripped.
    @Test func neuteringDoesNotMutateTheOriginal() {
        let live = OAuthCredential(accessToken: "t", refreshToken: "r",
                                   expiresAt: Date().addingTimeInterval(60))
        _ = live.neuteredForSession()
        #expect(live.refreshToken == "r")
    }

    @Test func seededCredentialSurvivesAKeychainRoundTrip() throws {
        let seeded = OAuthCredential(accessToken: "sk-ant-oat01-x", refreshToken: "r",
                                     expiresAt: Date(), scopes: ["user:inference"])
            .neuteredForSession()
        let reparsed = try #require(OAuthCredential(json: seeded.jsonString()))
        #expect(reparsed.refreshToken == nil)
        #expect(!reparsed.isAccessTokenExpired)
    }
}
