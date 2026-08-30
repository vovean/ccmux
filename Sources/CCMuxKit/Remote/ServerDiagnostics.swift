import CCMuxCore
import Foundation
import Security

/// A line of narration from inside a server connection attempt.
public typealias ServerTrace = @Sendable (String) -> Void

/// Turns a URLSession failure into something that can actually be diagnosed from a log.
///
/// `localizedDescription` is all the UI ever had, and "an SSL error has occurred" is the
/// same sentence for a dozen unrelated causes — a cancelled trust challenge, a protocol
/// version both ends refused, a proxy that closed the tunnel. The OSStatus buried under
/// `_kCFStreamErrorCodeKey` is the part that names which one, so it is dug out and handed
/// to Security for its own wording rather than a table here that could drift.
public enum ServerDiagnostics {
    /// The CFNetwork keys carrying the underlying stream error. Private API names, so they
    /// are read defensively: a missing one degrades the line, it does not break it.
    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    private static let streamErrorDomainKey = "_kCFStreamErrorDomainKey"

    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain)(\(ns.code))"]
        if let name = urlErrorName(ns) { parts.append(name) }
        parts.append(contentsOf: streamError(ns))
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code))")
            parts.append(contentsOf: streamError(underlying))
        }
        parts.append("\"\(ns.localizedDescription)\"")
        return parts.joined(separator: " ")
    }

    private static func streamError(_ ns: NSError) -> [String] {
        guard let code = ns.userInfo[streamErrorCodeKey] as? Int else { return [] }
        var out = ["osstatus=\(code)"]
        // Security's own wording for the status, so this can never disagree with the
        // system about what -9836 means.
        if let message = SecCopyErrorMessageString(OSStatus(code), nil) as String? {
            out.append("(\(message))")
        }
        if let domain = ns.userInfo[streamErrorDomainKey] as? Int {
            out.append("streamDomain=\(domain)")
        }
        return out
    }

    private static func urlErrorName(_ ns: NSError) -> String? {
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch ns.code {
        case NSURLErrorCancelled: return "cancelled"
        case NSURLErrorSecureConnectionFailed: return "secureConnectionFailed"
        case NSURLErrorServerCertificateUntrusted: return "serverCertificateUntrusted"
        case NSURLErrorServerCertificateHasBadDate: return "serverCertificateHasBadDate"
        case NSURLErrorServerCertificateHasUnknownRoot: return "serverCertificateHasUnknownRoot"
        case NSURLErrorServerCertificateNotYetValid: return "serverCertificateNotYetValid"
        case NSURLErrorClientCertificateRejected: return "clientCertificateRejected"
        case NSURLErrorCannotConnectToHost: return "cannotConnectToHost"
        case NSURLErrorNetworkConnectionLost: return "networkConnectionLost"
        case NSURLErrorTimedOut: return "timedOut"
        case NSURLErrorCannotFindHost: return "cannotFindHost"
        case NSURLErrorNotConnectedToInternet: return "notConnectedToInternet"
        default: return nil
        }
    }

    /// What a trust challenge was asked about, for the trace.
    public static func describe(_ space: URLProtectionSpace) -> String {
        "host=\(space.host):\(space.port) proto=\(space.protocol ?? "?") "
            + "method=\(space.authenticationMethod) "
            + "proxyType=\(space.proxyType ?? "none") isProxy=\(space.isProxy())"
    }
}
