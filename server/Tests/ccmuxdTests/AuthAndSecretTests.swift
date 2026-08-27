import CCMuxCore
import Foundation
import Testing
@testable import CCMuxDaemonKit

@Suite("Basic auth")
struct BasicAuthTests {
    private let credential = BasicAuthCredential(
        username: "ccmux",
        passwordHashHex: CryptoShim.sha256Hex(Data("hunter2".utf8)))

    @Test func theRightCredentialIsAccepted() {
        #expect(credential.accepts(username: "ccmux", password: "hunter2"))
    }

    @Test func awrongPasswordIsRefused() {
        #expect(!credential.accepts(username: "ccmux", password: "hunter3"))
    }

    @Test func aWrongUsernameIsRefused() {
        #expect(!credential.accepts(username: "someone", password: "hunter2"))
    }

    /// A prefix of the right password must not pass. The constant-time compare folds
    /// length into the result rather than returning early on it.
    @Test func aPrefixOfThePasswordIsRefused() {
        #expect(!credential.accepts(username: "ccmux", password: "hunter"))
        #expect(!credential.accepts(username: "ccmu", password: "hunter2"))
        #expect(!credential.accepts(username: "", password: ""))
    }

    @Test func theHeaderIsParsed() {
        let header = "Basic " + Data("ccmux:hunter2".utf8).base64EncodedString()
        let parsed = BasicAuthHeader.parse(header)
        #expect(parsed?.username == "ccmux")
        #expect(parsed?.password == "hunter2")
    }

    /// Split on the first colon only — a generated password may well contain one.
    @Test func aPasswordContainingAColonSurvives() {
        let header = "Basic " + Data("ccmux:pa:ss:word".utf8).base64EncodedString()
        let parsed = BasicAuthHeader.parse(header)
        #expect(parsed?.username == "ccmux")
        #expect(parsed?.password == "pa:ss:word")
    }

    @Test func rubbishHeadersAreRejectedRatherThanCrashing() {
        #expect(BasicAuthHeader.parse("Bearer abc") == nil)
        #expect(BasicAuthHeader.parse("Basic") == nil)
        #expect(BasicAuthHeader.parse("Basic !!!not-base64!!!") == nil)
        #expect(BasicAuthHeader.parse("Basic " + Data("nocolon".utf8).base64EncodedString()) == nil)
        #expect(BasicAuthHeader.parse("") == nil)
    }

    @Test func theAuthFileMustBeUsernameAndASha256() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("auth")
        try "ccmux:\(CryptoShim.sha256Hex(Data("pw".utf8)))\n".write(to: good, atomically: true,
                                                                     encoding: .utf8)
        let loaded = try BasicAuthCredential.load(from: good)
        #expect(loaded.username == "ccmux")
        #expect(loaded.accepts(username: "ccmux", password: "pw"))

        // A plaintext password in the file is the mistake worth catching loudly: it would
        // otherwise be silently hashed-and-compared against, and never match.
        let bad = dir.appendingPathComponent("bad")
        try "ccmux:plaintext\n".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try BasicAuthCredential.load(from: bad) }
    }
}

@Suite("Secret stores")
struct SecretStoreTests {
    @Test func theSealedFileRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyURL = dir.appendingPathComponent("master.key")
        let key = try EncryptedFileSecretStore.loadOrCreateKey(at: keyURL)
        let store = EncryptedFileSecretStore(fileURL: dir.appendingPathComponent("s.sealed"),
                                             key: key)
        try store.write("value-one", for: "a")
        try store.write("value-two", for: "b")
        #expect(try store.read("a") == "value-one")
        #expect(try store.keys() == ["a", "b"])

        try store.delete("a")
        #expect(try store.read("a") == nil)
        #expect(try store.keys() == ["b"])

        // Reopened with the same key, by a fresh instance, as a restart would.
        let reopened = EncryptedFileSecretStore(
            fileURL: dir.appendingPathComponent("s.sealed"),
            key: try EncryptedFileSecretStore.loadOrCreateKey(at: keyURL))
        #expect(try reopened.read("b") == "value-two")
    }

    @Test func thePlaintextIsNotOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sealed = dir.appendingPathComponent("s.sealed")
        let store = EncryptedFileSecretStore(
            fileURL: sealed,
            key: try EncryptedFileSecretStore.loadOrCreateKey(
                at: dir.appendingPathComponent("master.key")))
        try store.write("a-refresh-token-shaped-thing", for: "acct")
        let raw = String(decoding: try Data(contentsOf: sealed), as: UTF8.self)
        #expect(!raw.contains("a-refresh-token-shaped-thing"))
    }

    /// The failure that must never be quiet: opening with the wrong key has to throw, not
    /// return an empty dictionary. Carrying on empty would overwrite every live refresh
    /// token on the very next write.
    @Test func aWrongKeyRefusesInsteadOfLookingEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sealed = dir.appendingPathComponent("s.sealed")
        let right = try EncryptedFileSecretStore.loadOrCreateKey(
            at: dir.appendingPathComponent("master.key"))
        try EncryptedFileSecretStore(fileURL: sealed, key: right).write("v", for: "k")

        let wrong = try EncryptedFileSecretStore.loadOrCreateKey(
            at: dir.appendingPathComponent("other.key"))
        let store = EncryptedFileSecretStore(fileURL: sealed, key: wrong)
        #expect(throws: (any Error).self) { try store.read("k") }
        #expect(throws: (any Error).self) { try store.keys() }
    }

    @Test func aMissingFileIsSimplyEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedFileSecretStore(
            fileURL: dir.appendingPathComponent("absent.sealed"),
            key: try EncryptedFileSecretStore.loadOrCreateKey(
                at: dir.appendingPathComponent("master.key")))
        #expect(try store.keys().isEmpty)
        #expect(try store.read("anything") == nil)
    }

    /// OAuth credentials and API keys share one sealed file. They authenticate with
    /// different headers entirely, so an id colliding across the two would be a genuine
    /// confusion of credential shapes.
    @Test func prefixesKeepTheTwoCredentialShapesApart() throws {
        let base = InMemorySecretStore()
        let oauth = PrefixedSecretStore(base, prefix: "oauth:")
        let keys = PrefixedSecretStore(base, prefix: "apikey:")

        try oauth.write("credential-json", for: "same-id")
        try keys.write("sk-ant-secret", for: "same-id")

        #expect(try oauth.read("same-id") == "credential-json")
        #expect(try keys.read("same-id") == "sk-ant-secret")
        #expect(try oauth.keys() == ["same-id"])
        #expect(try keys.keys() == ["same-id"])
        #expect(try base.keys() == ["apikey:same-id", "oauth:same-id"])

        try oauth.delete("same-id")
        #expect(try keys.read("same-id") == "sk-ant-secret")
    }
}

@Suite("Server config")
struct ServerConfigTests {
    @Test func flagsAreParsed() throws {
        let config = try ServerConfig.parse(
            ["--data-dir", "/tmp/d", "--port", "9443", "--host", "127.0.0.1"], environment: [:])
        #expect(config.dataDir.path == "/tmp/d")
        #expect(config.port == 9443)
        #expect(config.host == "127.0.0.1")
        #expect(config.insecure == false)
        #expect(config.accountsFile.path == "/tmp/d/accounts.json")
    }

    @Test func theEnvironmentSuppliesTheDataDirectory() throws {
        let config = try ServerConfig.parse([], environment: ["CCMUXD_DATA_DIR": "/srv/ccmuxd"])
        #expect(config.dataDir.path == "/srv/ccmuxd")
        #expect(config.secretsFile.path == "/srv/ccmuxd/secrets.sealed")
    }

    @Test func aFlagOnTheCommandLineBeatsTheEnvironment() throws {
        let config = try ServerConfig.parse(["--data-dir", "/from/flag"],
                                            environment: ["CCMUXD_DATA_DIR": "/from/env"])
        #expect(config.dataDir.path == "/from/flag")
    }

    @Test func badInputIsRejected() {
        #expect(throws: (any Error).self) { try ServerConfig.parse(["--port"], environment: [:]) }
        #expect(throws: (any Error).self) {
            try ServerConfig.parse(["--port", "70000"], environment: [:])
        }
        #expect(throws: (any Error).self) {
            try ServerConfig.parse(["--port", "not-a-number"], environment: [:])
        }
        #expect(throws: (any Error).self) { try ServerConfig.parse(["--nonsense"], environment: [:]) }
    }
}
