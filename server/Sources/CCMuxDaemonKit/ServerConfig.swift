import CCMuxCore
import Foundation

public struct ServerConfig {
    public var dataDir = URL(fileURLWithPath: "/var/lib/ccmuxd")
    public var certPath = "/etc/ccmuxd/cert.pem"
    public var keyPath = "/etc/ccmuxd/key.pem"
    public var host = "0.0.0.0"
    public var port = 8443
    /// Off only for tests and for a run behind something else terminating TLS. Basic auth
    /// over cleartext hands over the credential and every access token with it, so the
    /// flag is deliberately awkward to reach for.
    public var insecure = false

    public var accountsFile: URL { dataDir.appendingPathComponent("accounts.json") }
    public var secretsFile: URL { dataDir.appendingPathComponent("secrets.sealed") }
    public var masterKeyFile: URL { dataDir.appendingPathComponent("master.key") }
    public var authFile: URL { dataDir.appendingPathComponent("auth") }

    public static func parse(_ arguments: [String], environment: [String: String]) throws
        -> ServerConfig {
        var config = ServerConfig()
        if let raw = environment["CCMUXD_DATA_DIR"], !raw.isEmpty {
            config.dataDir = URL(fileURLWithPath: raw)
        }
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else {
                    throw ServerError.usage("\(flag) needs a value")
                }
                return arguments[index]
            }
            switch flag {
            case "--data-dir": config.dataDir = URL(fileURLWithPath: try value())
            case "--cert": config.certPath = try value()
            case "--key": config.keyPath = try value()
            case "--host": config.host = try value()
            case "--port":
                let raw = try value()
                guard let parsed = Int(raw), (1...65535).contains(parsed) else {
                    throw ServerError.usage("--port must be 1-65535, got \(raw)")
                }
                config.port = parsed
            case "--insecure": config.insecure = true
            case "--help", "-h": throw ServerError.usage(Self.usage)
            default: throw ServerError.usage("unknown flag \(flag)\n\n\(Self.usage)")
            }
            index += 1
        }
        return config
    }

    public static let usage = """
    ccmuxd — holds ccmux's accounts and their refresh lineages.

      --data-dir PATH   accounts, sealed secrets and the auth file (default /var/lib/ccmuxd)
      --cert PATH       TLS certificate chain, PEM (default /etc/ccmuxd/cert.pem)
      --key PATH        TLS private key, PEM (default /etc/ccmuxd/key.pem)
      --host ADDR       bind address (default 0.0.0.0)
      --port N          bind port (default 8443)
      --insecure        serve plain HTTP — tests and TLS-terminating front ends only

    The auth file is `username:sha256-hex-of-password`, one line, mode 0600.
    scripts/install-ccmuxd.sh writes one and prints the password once.
    """
}

public enum ServerError: Error, LocalizedError {
    case usage(String)
    case startup(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let s), .startup(let s): return s
        }
    }
}

/// The single shared credential, per the design's basic-auth decision. One credential
/// means revoking one Mac rotates it for all of them; that tradeoff is recorded in
/// docs/server.md rather than papered over here.
public struct BasicAuthCredential: Sendable {
    public let username: String
    public let passwordHashHex: String

    public static func load(from url: URL) throws -> BasicAuthCredential {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ServerError.startup(
                "no auth file at \(url.path) — run scripts/install-ccmuxd.sh")
        }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 64 else {
            throw ServerError.startup(
                "auth file must be `username:sha256-hex-of-password`")
        }
        return BasicAuthCredential(username: parts[0], passwordHashHex: parts[1].lowercased())
    }

    /// Compares in constant time. A timing oracle on a shared password is not a
    /// theoretical concern when the endpoint is reachable from the internet.
    public func accepts(username candidateUser: String, password: String) -> Bool {
        let expected = Array(passwordHashHex.utf8)
        let actual = Array(CryptoShim.sha256Hex(Data(password.utf8)).utf8)
        let user = Array(username.utf8)
        let candidate = Array(candidateUser.utf8)

        var difference = UInt8(expected.count == actual.count ? 0 : 1)
        difference |= UInt8(user.count == candidate.count ? 0 : 1)
        for index in 0..<min(expected.count, actual.count) {
            difference |= expected[index] ^ actual[index]
        }
        for index in 0..<min(user.count, candidate.count) {
            difference |= user[index] ^ candidate[index]
        }
        return difference == 0
    }
}
