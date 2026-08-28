import Foundation

/// A namespaced view onto another store, so OAuth credentials and API keys can share one
/// sealed file without an account id in both ever colliding. They authenticate with
/// different headers entirely, and confusing the two shapes is the failure worth ruling
/// out structurally.
public struct PrefixedSecretStore: SecretStore {
    private let base: SecretStore
    private let prefix: String

    public init(_ base: SecretStore, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    public func read(_ key: String) throws -> String? { try base.read(prefix + key) }

    public func write(_ value: String, for key: String) throws {
        try base.write(value, for: prefix + key)
    }

    public func delete(_ key: String) throws { try base.delete(prefix + key) }

    public func keys() throws -> [String] {
        try base.keys().filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
