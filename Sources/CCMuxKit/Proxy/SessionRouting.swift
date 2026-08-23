import Foundation

/// What the proxy needs to know to keep a session running across accounts.
///
/// Deliberately narrow: the proxy does not know what an account or a limit window is, it
/// just asks "who should serve this" and "who could serve it later".
public protocol SessionRouting: AnyObject {
    /// The account and bearer token to use for the next request.
    func assignment(sessionID: String) -> (accountID: String, token: String)?

    /// Where to retry a request that `servedBy` refused, or nil to give up and let the
    /// refusal through. Assigning the session is the callee's business.
    ///
    /// `servedBy` matters: the account may have changed while the request was in flight,
    /// and a refusal from the old one must not drag the session somewhere the user did
    /// not choose.
    func failover(sessionID: String, model: String?, servedBy: String,
                  tried: Set<String>) -> (accountID: String, token: String)?

    /// The soonest moment any account could serve `model`, used to tell Claude Code when
    /// it is worth trying again.
    func soonestAvailability(model: String?) -> Date?
}
