import CCMuxCore
import Foundation

/// An HTTP proxy every outbound ccmux request is sent through.
///
/// Process-local: this configures ccmux's own URLSessions and nothing else. It does not
/// read or write system proxy settings, does not touch routes, and has no effect on
/// Claude Code or any other process.
///
/// The password is deliberately absent. Settings are stored as plaintext JSON in
/// Application Support, and a proxy URL usually carries credentials — those live in the
/// Keychain instead, keyed by `ProxyPasswordStore.account`.
public struct UpstreamProxy: Codable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?

    public init(host: String, port: Int, username: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// What the user sees; never includes the password.
    public var displayString: String {
        let credentials = username.map { "\($0)@" } ?? ""
        return "http://\(credentials)\(host):\(port)"
    }

    /// Parses what someone would paste from a shell — the same string they would put in
    /// HTTPS_PROXY, percent-encoding and all. Returns the password separately so the
    /// caller can route it to the Keychain rather than into settings.
    public static func parse(_ raw: String) -> (proxy: UpstreamProxy, password: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A bare host:port is a reasonable thing to type.
        if !text.contains("://") { text = "http://" + text }
        guard let url = URLComponents(string: text),
              let host = url.host, !host.isEmpty else { return nil }
        let port = url.port ?? 3128
        guard port > 0, port <= 65_535 else { return nil }
        // URLComponents percent-decodes `user` and `password` for us, which is what makes
        // a pasted `p%2Ass` arrive as the literal `p*ss` the proxy expects.
        let user = (url.user?.isEmpty == false) ? url.user : nil
        let password = (url.password?.isEmpty == false) ? url.password : nil
        return (UpstreamProxy(host: host, port: port, username: user), password)
    }
}
