import Foundation

public enum SecretStoreError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}

/// Where credentials live. One protocol so the server's account housekeeping is written
/// once against Keychain on macOS and an encrypted file on Linux.
///
/// Keys are account IDs. Values are opaque strings — an `OAuthCredential.jsonString()` or
/// a bare API key — because the store must never need to understand what it is holding.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
    /// Every key currently held, so the server can load its lineages at startup without
    /// trusting the accounts file to be in step with the secret store.
    func keys() throws -> [String]
}
