import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Several addresses for one server")
struct ServerAddressTests {
    /// Every settings.json written before failover existed has no `alternateURLs` at all,
    /// and a connection that fails to decode is a Mac that silently stops renewing every
    /// delegated account.
    @Test func aConnectionWrittenBeforeFailoverStillDecodes() throws {
        let json = """
        {"url":"https://10.0.0.1:8443","username":"ccmux","fingerprint":"abcd"}
        """
        let connection = try JSONDecoder().decode(ServerConnection.self,
                                                  from: Data(json.utf8))
        #expect(connection.url == "https://10.0.0.1:8443")
        #expect(connection.alternateURLs.isEmpty)
        #expect(connection.addresses == ["https://10.0.0.1:8443"])
    }

    @Test func theAddressListLeadsWithTheOneThatLastWorked() {
        let connection = ServerConnection(url: "https://a:8443",
                                          alternateURLs: ["https://b:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        #expect(connection.addresses == ["https://a:8443", "https://b:8443"])
    }

    /// A primary that also appears among the alternates would otherwise be tried twice,
    /// which on an unreachable address means paying its timeout twice per tick.
    @Test func aRepeatedAddressIsOnlyTriedOnce() {
        let connection = ServerConnection(
            url: "https://a:8443",
            alternateURLs: ["https://a:8443", "https://b:8443"],
            username: "ccmux", fingerprint: "abcd")
        #expect(connection.addresses == ["https://a:8443", "https://b:8443"])
    }

    @Test func promotingAnAlternateKeepsTheOthers() {
        var connection = ServerConnection(
            url: "https://a:8443",
            alternateURLs: ["https://b:8443", "https://c:8443"],
            username: "ccmux", fingerprint: "abcd")
        connection.promote("https://c:8443")
        #expect(connection.url == "https://c:8443")
        #expect(connection.alternateURLs == ["https://a:8443", "https://b:8443"])
        #expect(Set(connection.addresses).count == 3)
    }

    /// Nothing should be able to write an address into the connection that the user never
    /// agreed to — promotion reorders what is there, it does not add.
    @Test func promotingSomethingUnknownChangesNothing() {
        var connection = ServerConnection(url: "https://a:8443",
                                          alternateURLs: ["https://b:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        connection.promote("https://evil:8443")
        #expect(connection.url == "https://a:8443")
        #expect(connection.alternateURLs == ["https://b:8443"])
    }

    @Test func promotingTheCurrentPrimaryIsANoOp() {
        var connection = ServerConnection(url: "https://a:8443",
                                          alternateURLs: ["https://b:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        connection.promote("https://a:8443")
        #expect(connection.url == "https://a:8443")
        #expect(connection.alternateURLs == ["https://b:8443"])
    }

    // MARK: - Editing the list while connected

    /// Editing the list must not move a working connection off the address that is
    /// working for it — on a Mac whose other addresses are unreachable that costs a
    /// timeout every tick until the preference catches up.
    @Test func editingKeepsTheAddressInUseAtTheFront() {
        var connection = ServerConnection(url: "https://b:8443",
                                          alternateURLs: ["https://a:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        connection.setAddresses(["https://a:8443", "https://b:8443", "https://c:8443"])
        #expect(connection.url == "https://b:8443")
        #expect(connection.alternateURLs == ["https://a:8443", "https://c:8443"])
    }

    @Test func droppingTheAddressInUseFallsBackToTheFirstListed() {
        var connection = ServerConnection(url: "https://b:8443",
                                          alternateURLs: ["https://a:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        connection.setAddresses(["https://c:8443", "https://d:8443"])
        #expect(connection.url == "https://c:8443")
        #expect(connection.alternateURLs == ["https://d:8443"])
    }

    /// An empty list would leave the connection with nowhere to go while still claiming to
    /// be connected, and every delegated account would quietly stop renewing.
    @Test func anEmptyListIsRefusedRatherThanApplied() {
        var connection = ServerConnection(url: "https://a:8443",
                                          alternateURLs: ["https://b:8443"],
                                          username: "ccmux", fingerprint: "abcd")
        connection.setAddresses([])
        #expect(connection.url == "https://a:8443")
        #expect(connection.alternateURLs == ["https://b:8443"])
    }

    /// Editing addresses never touches the pin: an alternate that answers with a different
    /// certificate has to be refused, not silently adopted.
    @Test func editingLeavesTheCredentialsAndPinAlone() {
        var connection = ServerConnection(url: "https://a:8443", username: "ccmux",
                                          fingerprint: "abcd")
        connection.setAddresses(["https://x:8443", "https://y:8443"])
        #expect(connection.username == "ccmux")
        #expect(connection.fingerprint == "abcd")
    }

    // MARK: - What the connect field accepts

    @Test func commasAndSpacesBothSeparateAddresses() {
        let parsed = Engine.serverAddresses("10.0.0.1, 203.0.113.10:8443")
            .map(\.absoluteString)
        #expect(parsed == ["https://10.0.0.1:8443", "https://203.0.113.10:8443"])
    }

    @Test func aSingleAddressStillWorksUnchanged() {
        let parsed = Engine.serverAddresses("  ccmux.example.com  ").map(\.absoluteString)
        #expect(parsed == ["https://ccmux.example.com:8443"])
    }

    /// The same address typed twice, or once bare and once with the default port, is one
    /// address — pasting a list is exactly where that happens.
    @Test func duplicatesCollapseAfterNormalizing() {
        let parsed = Engine.serverAddresses("10.0.0.1 10.0.0.1:8443, 10.0.0.1")
            .map(\.absoluteString)
        #expect(parsed == ["https://10.0.0.1:8443"])
    }

    @Test func nothingUsableGivesNoAddresses() {
        #expect(Engine.serverAddresses("   ").isEmpty)
        #expect(Engine.serverAddresses(",,, ").isEmpty)
    }
}
