@_exported import CCMuxCore
import Foundation

/// The Darwin client's outbound path. Lives here rather than in `CCMuxCore` because
/// `UpstreamProxy` and URLSession proxy configuration are both client-side concerns —
/// the server talks to Anthropic directly.
public extension OAuthClient {
    /// A client whose refresh, profile, usage and probe calls all go through the proxy.
    /// Routing only the relay would look like the setting worked while token refreshes
    /// still went direct — and on a machine that needs the proxy, those are exactly the
    /// calls that would fail.
    static func proxied(_ proxy: UpstreamProxy?, password: String?) -> OAuthClient {
        guard proxy != nil else { return OAuthClient() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        ProxyTransport.apply(proxy, to: config)
        let auth = ProxyAuthenticator(
            credential: ProxyTransport.credential(for: proxy, password: password))
        return OAuthClient(transport: URLSessionTransport(
            session: URLSession(configuration: config, delegate: auth, delegateQueue: nil)))
    }
}
