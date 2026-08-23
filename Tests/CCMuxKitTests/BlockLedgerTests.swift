import Foundation
import Testing
@testable import CCMuxKit

@Suite("Blocked-session ledger")
struct BlockLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("A repeat of the same block is not worth announcing again")
    func announcesOnlyRealChanges() {
        var ledger = BlockLedger()
        let first = ledger.block(sessionID: "s", accountID: "a", model: "opus",
                                 reason: .pinned, now: t0)
        let repeated = ledger.block(sessionID: "s", accountID: "a", model: "opus",
                                    reason: .pinned, now: t0.addingTimeInterval(60))
        #expect(first)
        #expect(repeated == false)
        // The original time survives, so the UI can order by how long it has been stuck.
        #expect(ledger["s"]?.since == t0)

        let movedAccount = ledger.block(sessionID: "s", accountID: "b", model: "opus",
                                        reason: .pinned, now: t0)
        let movedModel = ledger.block(sessionID: "s", accountID: "b", model: "fable",
                                      reason: .pinned, now: t0)
        let movedReason = ledger.block(sessionID: "s", accountID: "b", model: "fable",
                                       reason: .noneEligible, now: t0)
        #expect(movedAccount)
        #expect(movedModel)
        #expect(movedReason)
    }

    /// Claude Code issues auxiliary requests on cheaper models. One of those succeeding
    /// says nothing about the model that was refused, and clearing on it wiped every
    /// indicator while the real work was still stuck.
    @Test("A success on another model does not clear the block")
    func anotherModelDoesNotClear() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "s", accountID: "a", model: "claude-fable-5",
                     reason: .pinned, now: t0)

        let auxiliary = ledger.served(sessionID: "s", accountID: "a",
                                      model: "claude-haiku-4-5-20251001")
        #expect(auxiliary == false)
        #expect(ledger["s"] != nil)

        let realWork = ledger.served(sessionID: "s", accountID: "a",
                                     model: "claude-fable-5")
        #expect(realWork)
        #expect(ledger["s"] == nil)
    }

    /// Proxy-level failover reassigns without going through the Engine, so a response
    /// from a different account is the only signal that the session moved.
    @Test("A success from another account clears the block")
    func anotherAccountClears() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "s", accountID: "a", model: "claude-fable-5",
                     reason: .noneEligible, now: t0)
        let cleared = ledger.served(sessionID: "s", accountID: "b",
                                    model: "claude-haiku-4-5-20251001")
        #expect(cleared)
        #expect(ledger.isEmpty)
    }

    @Test("A block with no known model clears on any success")
    func unknownModelClearsOnAnything() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "s", accountID: "a", model: nil, reason: .pinned, now: t0)
        let cleared = ledger.served(sessionID: "s", accountID: "a", model: "anything")
        #expect(cleared)
        #expect(ledger.isEmpty)
    }

    @Test("Serving a session that is not blocked changes nothing")
    func servingAnUnblockedSessionIsInert() {
        var ledger = BlockLedger()
        let acted = ledger.served(sessionID: "ghost", accountID: "a", model: "opus")
        #expect(acted == false)
        #expect(ledger.isEmpty)
    }

    @Test("Reaped sessions are pruned and reported")
    func pruningDropsDeadSessions() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "live", accountID: "a", model: nil, reason: .pinned, now: t0)
        ledger.block(sessionID: "dead", accountID: "a", model: nil, reason: .pinned, now: t0)

        let dropped = ledger.prune(liveSessionIDs: ["live"])
        #expect(dropped == ["dead"])
        #expect(ledger.count == 1)
        #expect(ledger["live"] != nil)
        let droppedAgain = ledger.prune(liveSessionIDs: ["live"])
        #expect(droppedAgain.isEmpty)
    }

    @Test("Entries come out oldest first")
    func orderedByAge() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "young", accountID: "a", model: nil, reason: .pinned,
                     now: t0.addingTimeInterval(600))
        ledger.block(sessionID: "old", accountID: "a", model: nil, reason: .pinned, now: t0)
        #expect(ledger.all.map(\.sessionID) == ["old", "young"])
    }

    @Test("Unblocking reports whether anything was there")
    func unblockReportsWhetherItActed() {
        var ledger = BlockLedger()
        ledger.block(sessionID: "s", accountID: "a", model: nil, reason: .pinned, now: t0)
        let acted = ledger.unblock("s")
        let again = ledger.unblock("s")
        #expect(acted)
        #expect(again == false)
    }
}
