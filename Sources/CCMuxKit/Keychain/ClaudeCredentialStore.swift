import CryptoKit
import Foundation

/// Reads and writes the Keychain items Claude Code itself uses.
///
/// Service name mirrors Claude Code's own derivation:
///   "Claude Code" + OAUTH_FILE_SUFFIX + "-credentials" + ("-" + sha256(NFC(dir))[0..8])
/// where the hash suffix appears only when the process is namespaced by
/// CLAUDE_CONFIG_DIR or CLAUDE_SECURESTORAGE_CONFIG_DIR. OAUTH_FILE_SUFFIX is "" on
/// prod. Getting this wrong reads a different item, which presents as "logged out".
public enum ClaudeCredentialStore {
    public static let globalService = "Claude Code-credentials"

    public static func service(forNamespace dir: URL) -> String {
        let path = dir.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(globalService)-\(hex.prefix(8))"
    }

    public static func readGlobal() throws -> OAuthCredential? {
        guard let raw = try Keychain.read(service: globalService) else { return nil }
        return OAuthCredential(json: raw)
    }

    public static func read(namespace dir: URL) throws -> OAuthCredential? {
        guard let raw = try Keychain.read(service: service(forNamespace: dir)) else { return nil }
        return OAuthCredential(json: raw)
    }

    public static func write(_ credential: OAuthCredential, namespace dir: URL) throws {
        try Keychain.write(service: service(forNamespace: dir), value: credential.jsonString())
    }

    public static func clear(namespace dir: URL) throws {
        try Keychain.delete(service: service(forNamespace: dir))
    }
}

/// Where ccmux keeps its own copy of each account's credential.
public enum AccountCredentialStore {
    static let service = "ccmux-credentials"

    public static func read(_ accountID: String) throws -> OAuthCredential? {
        guard let raw = try Keychain.read(service: service, account: accountID) else { return nil }
        return OAuthCredential(json: raw)
    }

    public static func write(_ credential: OAuthCredential, for accountID: String) throws {
        try Keychain.write(service: service, account: accountID, value: credential.jsonString())
    }

    public static func delete(_ accountID: String) throws {
        try Keychain.delete(service: service, account: accountID)
    }
}
