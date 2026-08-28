import Foundation

/// Why a server could not produce a token.
///
/// The distinction is the whole point: a server that is merely unreachable must not mark
/// an account as needing re-login, but a server that says it holds no usable credential
/// for the account is reporting a dead lineage — and hiding that behind a transient error
/// leaves a green row, no repair button, and every session on it answering 401.
public enum RemoteTokenError: Error, LocalizedError, Equatable {
    /// The server has no usable credential for this account. Its lineage is dead and only
    /// a fresh sign-in recovers it.
    case noUsableCredential(String)

    public var errorDescription: String? {
        switch self {
        case .noUsableCredential(let detail):
            return detail.isEmpty
                ? "The account server has no working credential for this account."
                : detail
        }
    }
}

/// Where a delegated account's access tokens come from.
///
/// Narrow on purpose. `TokenVault` needs exactly one thing from a ccmuxd — a usable token
/// — and keeping the protocol to that makes it impossible for the client to accidentally
/// depend on holding a refresh token it is no longer entitled to.
public protocol RemoteTokenSource: Sendable {
    func grant(for accountID: String) async throws -> TokenGrant
}
