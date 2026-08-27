import Foundation

/// Where a delegated account's access tokens come from.
///
/// Narrow on purpose. `TokenVault` needs exactly one thing from a ccmuxd — a usable token
/// — and keeping the protocol to that makes it impossible for the client to accidentally
/// depend on holding a refresh token it is no longer entitled to.
public protocol RemoteTokenSource: Sendable {
    func grant(for accountID: String) async throws -> TokenGrant
}
