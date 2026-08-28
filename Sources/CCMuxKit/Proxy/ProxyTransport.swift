import CCMuxCore
import Foundation

/// Builds the URLSession pieces that route ccmux's own traffic through an upstream proxy.
public enum ProxyTransport {
    /// Applies the proxy to a session configuration. Both HTTP and HTTPS are set: the
    /// inference endpoint is HTTPS and reached by CONNECT, but the OAuth and usage calls
    /// share the same session and there is no reason for the two to differ.
    public static func apply(_ proxy: UpstreamProxy?,
                             to configuration: URLSessionConfiguration) {
        guard let proxy else {
            configuration.connectionProxyDictionary = nil
            return
        }
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: proxy.host,
            kCFNetworkProxiesHTTPPort as String: proxy.port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: proxy.host,
            kCFNetworkProxiesHTTPSPort as String: proxy.port,
            // Never send loopback through the proxy. Nothing does today, but the OAuth
            // callback and the control socket both live here, and routing them out to a
            // proxy would be a baffling failure to diagnose later.
            kCFNetworkProxiesExceptionsList as String: [
                "localhost", "127.0.0.1", "::1", "*.local",
            ],
        ]
    }

    /// Answers a proxy's authentication challenge.
    ///
    /// Credentials cannot be passed reliably through `connectionProxyDictionary` — URLSession
    /// asks for them instead, once per connection. Returning `.performDefaultHandling` for
    /// anything else matters: this must never intercept the TLS server-trust challenge for
    /// api.anthropic.com.
    public static func respond(
        to challenge: URLAuthenticationChallenge,
        credential: URLCredential?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodHTTPBasic
                || challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodDefault,
              challenge.protectionSpace.isProxy() else {
            return (.performDefaultHandling, nil)
        }
        // A second attempt means the credentials were rejected; retrying the same ones
        // would loop.
        guard challenge.previousFailureCount == 0, let credential else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, credential)
    }

    public static func credential(for proxy: UpstreamProxy?,
                                  password: String?) -> URLCredential? {
        guard let proxy, let username = proxy.username, !username.isEmpty,
              let password, !password.isEmpty else { return nil }
        return URLCredential(user: username, password: password, persistence: .forSession)
    }
}


/// Answers proxy auth for sessions that have no delegate of their own.
///
/// Strongly held by its URLSession, so it lives as long as the session does; the session
/// is replaced whenever the proxy setting changes.
public final class ProxyAuthenticator: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential?

    public init(credential: URLCredential?) {
        self.credential = credential
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                         URLCredential?) -> Void) {
        let (disposition, chosen) = ProxyTransport.respond(to: challenge,
                                                           credential: credential)
        completionHandler(disposition, chosen)
    }
}
