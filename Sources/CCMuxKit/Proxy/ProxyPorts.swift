import Foundation

/// Which ports session proxies listen on.
///
/// Deliberately outside the kernel's ephemeral range (`net.inet.ip.portrange.hifirst`
/// to `hilast`, 49152–65535 on macOS): a port in that range is one the kernel may hand
/// to *any* process opening an outbound socket, so a session's port can be gone by the
/// time ccmux restarts and tries to rebind it — and the port is baked into that
/// session's ANTHROPIC_BASE_URL, so it cannot move.
public enum ProxyPorts {
    public static let range: ClosedRange<UInt16> = 18000...18999

    /// Ports to try, in order. Bounded because each attempt is a real bind: a band this
    /// size is never exhausted in practice, and trying a thousand of them to prove it
    /// would just delay the session's start.
    public static func candidates(avoiding taken: Set<UInt16>, limit: Int = 32) -> [UInt16] {
        var found: [UInt16] = []
        for port in range where !taken.contains(port) {
            found.append(port)
            if found.count == limit { break }
        }
        return found
    }

    public static func isOurs(_ port: UInt16) -> Bool { range.contains(port) }
}
