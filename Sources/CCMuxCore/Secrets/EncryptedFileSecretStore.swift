import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The Linux secret store: one AES-GCM sealed file, keyed by a 32-byte master key kept
/// beside it at 0600.
///
/// The encryption buys less than it looks like — anything that can read the sealed file
/// can almost always read the key next to it. What it does buy is that a stray backup,
/// a copied volume, or a `docker cp` of the data directory alone does not hand over live
/// refresh tokens. The real boundary is filesystem permissions, which is why both files
/// are written 0600 and the directory 0700.
public final class EncryptedFileSecretStore: SecretStore, @unchecked Sendable {
    private let fileURL: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    /// Loads or creates the master key. Generating it here rather than asking the
    /// operator for one keeps the install script from having to handle key material.
    public static func loadOrCreateKey(at url: URL) throws -> SymmetricKey {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        if fm.fileExists(atPath: url.path) {
            throw SecretStoreError.failed("master key at \(url.path) is not 32 bytes")
        }
        let fresh = CryptoShim.randomBytes(32)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: url.path, contents: fresh,
                            attributes: [.posixPermissions: 0o600]) else {
            throw SecretStoreError.failed("could not create master key at \(url.path)")
        }
        return SymmetricKey(data: fresh)
    }

    public init(fileURL: URL, key: SymmetricKey) {
        self.fileURL = fileURL
        self.key = key
    }

    public func read(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try load()[key]
    }

    public func write(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try load()
        all[key] = value
        try save(all)
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try load()
        guard all.removeValue(forKey: key) != nil else { return }
        try save(all)
    }

    public func keys() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try load().keys.sorted()
    }

    // MARK: - Sealed file

    private func load() throws -> [String: String] {
        guard let sealed = try? Data(contentsOf: fileURL), !sealed.isEmpty else { return [:] }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode([String: String].self, from: plaintext)
        } catch {
            // Refusing loudly is the only safe move: carrying on with an empty dictionary
            // would silently overwrite every live refresh token on the next write.
            throw SecretStoreError.failed(
                "could not open \(fileURL.lastPathComponent) — wrong master key?")
        }
    }

    private func save(_ all: [String: String]) throws {
        let plaintext = try JSONEncoder().encode(all)
        guard let sealed = try AES.GCM.seal(plaintext, using: key).combined else {
            throw SecretStoreError.failed("could not seal the secret store")
        }
        // Written to a unique temp then moved: a truncated write here loses every
        // credential the server holds.
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try sealed.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
