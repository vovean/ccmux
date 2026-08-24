import Foundation
import Testing
@testable import CCMuxKit

@Suite("Proxy URL parsing")
struct UpstreamProxyParseTests {
    /// The point is that someone can paste exactly what they already have in HTTPS_PROXY,
    /// percent-encoding and all, and that the password never lands in settings.
    @Test("A full URL splits into settings and a secret")
    func parsesFullURL() throws {
        let parsed = try #require(UpstreamProxy.parse("http://bob:p%2Aa%5Ess@10.0.0.9:3128"))
        #expect(parsed.proxy.host == "10.0.0.9")
        #expect(parsed.proxy.port == 3128)
        #expect(parsed.proxy.username == "bob")
        #expect(parsed.password == "p*a^ss", "percent-encoding must be decoded")
        // Whatever is displayed or written to disk must not carry the password.
        #expect(!parsed.proxy.displayString.contains("p*a^ss"))
        let encoded = try JSONEncoder().encode(parsed.proxy)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("p*a^ss"))
    }

    @Test("A bare host:port is accepted")
    func parsesBareHostPort() throws {
        let parsed = try #require(UpstreamProxy.parse("proxy.local:8080"))
        #expect(parsed.proxy.host == "proxy.local")
        #expect(parsed.proxy.port == 8080)
        #expect(parsed.proxy.username == nil)
        #expect(parsed.password == nil)
    }

    @Test("A host with no port defaults to 3128")
    func defaultsPort() throws {
        let parsed = try #require(UpstreamProxy.parse("http://proxy.local"))
        #expect(parsed.proxy.port == 3128)
    }

    @Test("Nonsense is rejected rather than half-accepted")
    func rejectsNonsense() {
        #expect(UpstreamProxy.parse("") == nil)
        #expect(UpstreamProxy.parse("   ") == nil)
        #expect(UpstreamProxy.parse("http://") == nil)
        #expect(UpstreamProxy.parse("http://host:0") == nil)
        #expect(UpstreamProxy.parse("http://host:99999") == nil)
    }

    @Test("Settings written before this feature still decode")
    func settingsMigration() throws {
        let legacy = #"{"warnThresholdPercent":3,"autoSwitch":"immediate"}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        #expect(decoded.upstreamProxy == nil)
        #expect(decoded.warnThresholdPercent == 3)
    }
}

@Suite("Proxy authentication handling")
struct ProxyAuthTests {
    private func challenge(method: String, isProxy: Bool,
                           failures: Int = 0) -> URLAuthenticationChallenge {
        let space = isProxy
            ? URLProtectionSpace(proxyHost: "10.0.0.9", port: 3128,
                                 type: NSURLProtectionSpaceHTTPProxy, realm: nil,
                                 authenticationMethod: method)
            : URLProtectionSpace(host: "api.anthropic.com", port: 443,
                                 protocol: "https", realm: nil,
                                 authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                          previousFailureCount: failures,
                                          failureResponse: nil, error: nil,
                                          sender: DummySender())
    }

    private let credential = URLCredential(user: "bob", password: "s3cret",
                                           persistence: .forSession)

    @Test("A proxy challenge is answered with the credential")
    func answersProxyChallenge() {
        let (disposition, chosen) = ProxyTransport.respond(
            to: challenge(method: NSURLAuthenticationMethodHTTPBasic, isProxy: true),
            credential: credential)
        #expect(disposition == .useCredential)
        #expect(chosen?.user == "bob")
    }

    /// The single most dangerous mistake here would be answering the TLS server-trust
    /// challenge for api.anthropic.com with a proxy password, or overriding trust.
    @Test("A server trust challenge is left entirely alone")
    func neverInterceptsServerTrust() {
        let (disposition, chosen) = ProxyTransport.respond(
            to: challenge(method: NSURLAuthenticationMethodServerTrust, isProxy: false),
            credential: credential)
        #expect(disposition == .performDefaultHandling)
        #expect(chosen == nil)
    }

    @Test("A non-proxy basic challenge is not answered with the proxy password")
    func neverLeaksToOrigin() {
        let (disposition, _) = ProxyTransport.respond(
            to: challenge(method: NSURLAuthenticationMethodHTTPBasic, isProxy: false),
            credential: credential)
        #expect(disposition == .performDefaultHandling)
    }

    /// Retrying rejected credentials would loop forever against the proxy.
    @Test("Rejected credentials are not retried")
    func doesNotRetryRejected() {
        let (disposition, _) = ProxyTransport.respond(
            to: challenge(method: NSURLAuthenticationMethodHTTPBasic, isProxy: true,
                          failures: 1),
            credential: credential)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test("With no credential the challenge is declined, not left hanging")
    func declinesWithoutCredential() {
        let (disposition, _) = ProxyTransport.respond(
            to: challenge(method: NSURLAuthenticationMethodHTTPBasic, isProxy: true),
            credential: nil)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test("A credential is only built when both halves are present")
    func credentialRequiresBothHalves() {
        let withUser = UpstreamProxy(host: "h", port: 3128, username: "bob")
        let anonymous = UpstreamProxy(host: "h", port: 3128)
        #expect(ProxyTransport.credential(for: withUser, password: "s") != nil)
        #expect(ProxyTransport.credential(for: withUser, password: nil) == nil)
        #expect(ProxyTransport.credential(for: withUser, password: "") == nil)
        #expect(ProxyTransport.credential(for: anonymous, password: "s") == nil)
        #expect(ProxyTransport.credential(for: nil, password: "s") == nil)
    }
}

private final class DummySender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@Suite("Proxy is applied to the session configuration")
struct ProxyConfigurationTests {
    @Test("Both HTTP and HTTPS are pointed at the proxy")
    func appliesToConfiguration() throws {
        let config = URLSessionConfiguration.ephemeral
        ProxyTransport.apply(UpstreamProxy(host: "10.0.0.9", port: 3128), to: config)
        let dict = try #require(config.connectionProxyDictionary)
        #expect(dict[kCFNetworkProxiesHTTPSProxy as String] as? String == "10.0.0.9")
        #expect(dict[kCFNetworkProxiesHTTPSPort as String] as? Int == 3128)
        #expect(dict[kCFNetworkProxiesHTTPProxy as String] as? String == "10.0.0.9")
        // Loopback must never be proxied: the OAuth callback lives there.
        let exceptions = dict[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
        #expect(exceptions.contains("127.0.0.1"))
        #expect(exceptions.contains("localhost"))
    }

    @Test("Clearing the proxy removes it rather than leaving a stale one")
    func clearsConfiguration() {
        let config = URLSessionConfiguration.ephemeral
        ProxyTransport.apply(UpstreamProxy(host: "10.0.0.9", port: 3128), to: config)
        ProxyTransport.apply(nil, to: config)
        #expect(config.connectionProxyDictionary == nil)
    }
}
