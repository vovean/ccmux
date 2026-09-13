import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// What a session is seeded as, versus what currently serves it. Crossing an
/// organisation boundary mid-session changes which managed plugins Claude Code must
/// load, which then blocks every model switch after it.
@Suite("Session identity")
struct SessionIdentityTests {
    @Test func twoAccountsInOneOrganisationMayShareAnIdentity() {
        #expect(SessionManager.sameOrganisation("org-emcd", "org-emcd"))
    }

    @Test func accountsInDifferentOrganisationsMayNot() {
        #expect(!SessionManager.sameOrganisation("org-emcd", "org-1win"))
    }

    /// An API key carries no organisation, and neither does an account whose profile has
    /// not been read yet. Neither can be shown to leave the identity where it was, so the
    /// answer is no and the seed stays put.
    @Test func anUnknownOrganisationCountsAsDifferent() {
        #expect(!SessionManager.sameOrganisation(nil, "org-emcd"))
        #expect(!SessionManager.sameOrganisation("org-emcd", nil))
        #expect(!SessionManager.sameOrganisation(nil, nil))
        // Empty is the same as absent: a blank string matching a blank string must not
        // read as two accounts agreeing about anything.
        #expect(!SessionManager.sameOrganisation("", ""))
    }

    /// The move the user asked for is taken whole — including onto an API key, which
    /// carries no organisation at all and would otherwise strand the session on the
    /// placeholder credential that seeds an API-key launch.
    @Test func anExplicitMoveAlwaysTakesTheIdentityWithIt() {
        #expect(SessionManager.mayReseed(reason: .explicit, seededOrg: "org-emcd",
                                         targetOrg: "org-1win"))
        #expect(SessionManager.mayReseed(reason: .explicit, seededOrg: "org-emcd",
                                         targetOrg: nil))
        #expect(SessionManager.mayReseed(reason: .explicit, seededOrg: nil, targetOrg: nil))
    }

    /// Failover and rebalance exist to keep the session serving, so they move what
    /// serves it and leave what it is alone.
    @Test func aRotationOnlyCarriesTheIdentityInsideOneOrganisation() {
        #expect(SessionManager.mayReseed(reason: .rotation, seededOrg: "org-emcd",
                                         targetOrg: "org-emcd"))
        #expect(!SessionManager.mayReseed(reason: .rotation, seededOrg: "org-emcd",
                                          targetOrg: "org-1win"))
        // An API key has no organisation, so a rotation onto one cannot be shown to
        // leave the identity where it was.
        #expect(!SessionManager.mayReseed(reason: .rotation, seededOrg: "org-emcd",
                                          targetOrg: nil))
        #expect(!SessionManager.mayReseed(reason: .rotation, seededOrg: nil,
                                          targetOrg: "org-emcd"))
    }

    @Test func aNewSessionIsSeededAsWhateverItLaunchedOn() {
        let record = SessionRecord(id: "s1", pid: 1, port: 18000, accountID: "acct-emcd",
                                   policyName: "opus", cwd: "/tmp")
        #expect(record.seededAccountID == "acct-emcd")
    }

    @Test func theSeededAccountSurvivesAJSONRoundTrip() throws {
        var record = SessionRecord(id: "s1", pid: 1, port: 18000, accountID: "acct-1win",
                                   policyName: "opus", cwd: "/tmp")
        record.seededAccountID = "acct-emcd"
        let data = try JSONStore.encoder.encode(record)
        let back = try JSONStore.decoder.decode(SessionRecord.self, from: data)
        #expect(back.accountID == "acct-1win")
        #expect(back.seededAccountID == "acct-emcd")
    }

    /// A sessions.json written before this field existed must not decode to an empty
    /// identity: `Store` falls back to defaults on a failed decode, which would drop
    /// every live session's record on upgrade.
    @Test func aSessionWrittenBeforeTheFieldExistedKeepsItsAccount() throws {
        let legacy = Data("""
        {"id":"s1","pid":42,"port":18000,"accountID":"acct-emcd",
         "policyName":"opus","cwd":"/tmp","spendUSD":0}
        """.utf8)
        let record = try JSONStore.decoder.decode(SessionRecord.self, from: legacy)
        #expect(record.accountID == "acct-emcd")
        #expect(record.seededAccountID == "acct-emcd")
    }
}
