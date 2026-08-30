import Foundation
import Testing

/// The shipped Info.plist, read from the repository rather than from a bundle: the test
/// binary has no app bundle of its own, which is the very difference that hid this bug.
private func shippedInfoPlist() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CCMuxKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
    return try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any] ?? [:]
}

@Suite("App Transport Security")
struct AppTransportSecurityTests {
    /// ccmuxd is a bare IP with a self-signed certificate, and ATS rejects that on its own
    /// terms — it evaluates the chain itself, so accepting the trust in the URLSession
    /// delegate changes nothing. Without this key the app completed the handshake up to
    /// the certificate and then closed the connection, on every Mac, with no log line and
    /// nothing but "an SSL error has occurred" to go on. The same code outside an app
    /// bundle worked, which is what made it look like one machine's fault for a day.
    @Test func arbitraryLoadsAreAllowedSoASelfSignedCcmuxdCanBeReached() throws {
        let plist = try shippedInfoPlist()
        let ats = plist["NSAppTransportSecurity"] as? [String: Any]
        #expect(ats?["NSAllowsArbitraryLoads"] as? Bool == true)
    }

    /// Turning ATS off globally is the only way to name a host that has no domain name, so
    /// the hosts that *do* have one are tightened back individually. Anthropic's endpoints
    /// carry every credential this app exists to manage.
    @Test func anthropicKeepsTheStrictSettingsAtsWouldHaveGiven() throws {
        let plist = try shippedInfoPlist()
        let ats = plist["NSAppTransportSecurity"] as? [String: Any]
        let domains = ats?["NSExceptionDomains"] as? [String: Any]
        let anthropic = domains?["anthropic.com"] as? [String: Any]
        #expect(anthropic?["NSIncludesSubdomains"] as? Bool == true)
        #expect(anthropic?["NSExceptionRequiresForwardSecrecy"] as? Bool == true)
        #expect(anthropic?["NSExceptionMinimumTLSVersion"] as? String == "TLSv1.2")
    }
}
