import Foundation

/// A secret store that outlives nothing. For tests, and for `--ephemeral` runs of the
/// server where credentials should not touch the disk at all.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    public init(_ items: [String: String] = [:]) { self.items = items }

    public func read(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func write(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: key)
    }

    public func keys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.sorted()
    }
}
