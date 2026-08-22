import Foundation

/// What the proxy needs to know to keep a session running across accounts.
///
/// Deliberately narrow: the proxy does not know what an account or a limit window is, it
/// just asks "who should serve this" and "who could serve it later".
public protocol SessionRouting: AnyObject {
    /// The account and bearer token to use for the next request.
    func assignment(sessionID: String) -> (accountID: String, token: String)?

    /// Another account that can serve `model` right now, excluding ones already tried on
    /// this request. Assigning the session to it is the callee's business.
    func failover(sessionID: String, model: String?,
                  tried: Set<String>) -> (accountID: String, token: String)?

    /// The soonest moment any account could serve `model`, used to tell Claude Code when
    /// it is worth trying again.
    func soonestAvailability(model: String?) -> Date?
}
