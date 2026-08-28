import CCMuxCore
import Foundation

/// What the proxy needs to know to keep a session running across accounts.
///
/// Deliberately narrow: the proxy does not know what an account or a limit window is, it
/// just asks "who should serve this" and "who could serve it later".
/// How a request authenticates. The two schemes are mutually exclusive on the wire, so
/// the proxy has to know which one it is holding rather than just "a token".
public enum ProxyCredential: Equatable {
    case oauth(String)
    case apiKey(String)
}

public struct SessionAssignment: Equatable {
    public let accountID: String
    public let credential: ProxyCredential

    public init(accountID: String, credential: ProxyCredential) {
        self.accountID = accountID
        self.credential = credential
    }
}

public protocol SessionRouting: AnyObject {
    /// The account and bearer token to use for the next request.
    func assignment(sessionID: String) -> SessionAssignment?

    /// Where to retry a request that `servedBy` refused, or nil to give up and let the
    /// refusal through. Assigning the session is the callee's business.
    ///
    /// `servedBy` matters: the account may have changed while the request was in flight,
    /// and a refusal from the old one must not drag the session somewhere the user did
    /// not choose.
    func failover(sessionID: String, model: String?, servedBy: String,
                  tried: Set<String>) -> SessionAssignment?

    /// The soonest moment this session could be served `model`, used to tell Claude Code
    /// when it is worth trying again.
    ///
    /// Session-scoped on purpose: a session ccmux may not move can only ever be served by
    /// its own account, and naming an earlier moment belonging to some other account just
    /// sends Claude Code back into the same refusal.
    func soonestAvailability(model: String?, for sessionID: String) -> Date?
}
