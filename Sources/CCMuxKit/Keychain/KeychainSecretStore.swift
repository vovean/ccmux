import CCMuxCore
import Foundation

/// The Darwin secret store. `keys()` is the one operation `security` will not do — it
/// can read, write and delete an item by name but not enumerate a service — so the
/// caller supplies the account list it already has.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let knownKeys: @Sendable () -> [String]

    public init(service: String, knownKeys: @escaping @Sendable () -> [String] = { [] }) {
        self.service = service
        self.knownKeys = knownKeys
    }

    public func read(_ key: String) throws -> String? {
        try Keychain.read(service: service, account: key)
    }

    public func write(_ value: String, for key: String) throws {
        try Keychain.write(service: service, account: key, value: value)
    }

    public func delete(_ key: String) throws {
        try Keychain.delete(service: service, account: key)
    }

    public func keys() throws -> [String] { knownKeys() }
}
