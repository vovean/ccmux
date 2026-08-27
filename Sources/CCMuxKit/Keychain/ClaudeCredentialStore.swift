import CCMuxCore
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
        let hex = CryptoShim.sha256Hex(Data(path.utf8))
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

/// Anthropic API keys, kept apart from the OAuth items so nothing can confuse the two
/// credential shapes — they authenticate with different headers entirely.
public enum APIKeyStore {
    static let service = "ccmux-apikeys"

    public static func read(_ accountID: String) throws -> String? {
        try Keychain.read(service: service, account: accountID)
    }

    public static func write(_ key: String, for accountID: String) throws {
        try Keychain.write(service: service, account: accountID, value: key)
    }

    public static func delete(_ accountID: String) throws {
        try Keychain.delete(service: service, account: accountID)
    }
}

/// The upstream proxy password. Its own service so it is never confused with an account
/// credential, and out of settings.json because that file is plaintext on disk.
public enum ProxyPasswordStore {
    static let service = "ccmux-proxy"
    static let account = "upstream"

    public static func read() throws -> String? {
        try Keychain.read(service: service, account: account)
    }

    public static func write(_ password: String?) throws {
        guard let password, !password.isEmpty else {
            try? Keychain.delete(service: service, account: account)
            return
        }
        try Keychain.write(service: service, account: account, value: password)
    }
}

/// The ccmuxd basic-auth password. Its own service, and out of settings.json for the same
/// reason as the proxy password: that file is plaintext on disk.
public enum ServerPasswordStore {
    static let service = "ccmux-server"
    static let account = "basic-auth"

    public static func read() throws -> String? {
        try Keychain.read(service: service, account: account)
    }

    public static func write(_ password: String?) throws {
        guard let password, !password.isEmpty else {
            try? Keychain.delete(service: service, account: account)
            return
        }
        try Keychain.write(service: service, account: account, value: password)
    }
}
