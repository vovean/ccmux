import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 and secure random, spelled once so the call sites do not each need to know
/// which crypto module this platform has.
///
/// The digest is not decorative: `ClaudeCredentialStore` derives Claude Code's Keychain
/// service name from it, and PKCE derives the challenge from it. Both must agree
/// byte-for-byte with what Claude Code and Anthropic compute.
public enum CryptoShim {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        sha256(data).hexEncoded()
    }

    /// `SystemRandomNumberGenerator` is the CSPRNG on both platforms (arc4random on
    /// Darwin, getrandom on Linux), which `SecRandomCopyBytes` was only ever a
    /// Darwin-specific spelling of.
    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count { bytes.append(UInt8.random(in: 0...255, using: &generator)) }
        return Data(bytes)
    }
}

public extension Data {
    /// The encoding that decides which Keychain item is read and what value is written,
    /// so it exists once.
    func hexEncoded() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
