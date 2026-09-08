import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Stats selection")
struct StatsSelectionTests {
    static let noon = Date(timeIntervalSince1970: 1_788_000_000)

    static func totals(_ input: Int, cost: Double = 1,
                       unpriced: [String] = []) -> UsageTotals {
        UsageTotals(requests: 1, input: input, costUSD: cost, unpricedModels: unpriced)
    }

    static func series(_ id: String, machine: String = "mac-1",
                       machineLabel: String = "studio", session: String = "sess-1",
                       name: String = "api-gateway", account: String = "acct-1",
                       fingerprint: String? = nil, label: String = "Work",
                       model: String = "claude-opus-5", input: Int,
                       unpriced: [String] = []) -> UsageSeries {
        UsageSeries(id: id, machineID: machine, machineLabel: machineLabel,
                    sessionID: session, sessionName: name, accountID: account,
                    accountFingerprint: fingerprint, accountLabel: label, model: model,
                    totals: totals(input, unpriced: unpriced),
                    points: [UsagePoint(at: noon, requests: 1, input: input, costUSD: 1,
                                        unpriced: !unpriced.isEmpty)])
    }

    static func response(_ series: [UsageSeries],
                         accounts: [UsageAccountTotals]) -> UsageStatsResponse {
        UsageStatsResponse(range: .day, bucketSeconds: 300,
                           from: noon.addingTimeInterval(-86400), to: noon,
                           totals: UsageTotals(), accounts: accounts, series: series)
    }

    static var sample: UsageStatsResponse {
        response([
            series("a", session: "sess-1", input: 500),
            series("b", session: "sess-2", model: "claude-fable-5-1", input: 300),
            series("c", machine: "mac-2", machineLabel: "laptop", session: "sess-3",
                   account: "local-uuid", fingerprint: "fp-1", label: "Billing",
                   input: 200),
        ], accounts: [
            UsageAccountTotals(accountID: "acct-1", accountLabel: "Work",
                               kind: .subscription, totals: totals(800)),
            UsageAccountTotals(accountID: "local-uuid", accountFingerprint: "fp-1",
                               accountLabel: "Billing", kind: .apiKey,
                               totals: totals(200)),
        ])
    }

    @Test func noFilterKeepsEverything() {
        let selection = StatsSelection.apply(StatsFilter(), to: Self.sample)
        #expect(selection.drawn.count == 3)
        #expect(selection.matchedCount == 3)
        #expect(selection.totals.input == 1000)
        #expect(selection.accounts.count == 2)
    }

    /// An API key's account id is minted per Mac, so the fingerprint is what identifies
    /// it — the same rule the session view follows.
    @Test func anAccountFilterMatchesOnTheFingerprintWhereThereIsOne() {
        let selection = StatsSelection.apply(StatsFilter(accounts: ["fp-1"]),
                                             to: Self.sample)
        #expect(selection.drawn.map(\.id) == ["c"])
        #expect(selection.totals.input == 200)
        #expect(selection.accounts.map(\.accountLabel) == ["Billing"])
    }

    @Test func aModelFilterNarrowsBothTheChartAndTheTable() {
        let selection = StatsSelection.apply(StatsFilter(models: ["claude-fable-5-1"]),
                                             to: Self.sample)
        #expect(selection.drawn.map(\.id) == ["b"])
        #expect(selection.totals.input == 300)
        // The table is rebuilt from what matched, not taken from the answer, so it
        // cannot disagree with the chart beside it.
        #expect(selection.accounts.count == 1)
        #expect(selection.accounts.first?.totals.input == 300)
    }

    @Test func bothFiltersApplyTogether() {
        let selection = StatsSelection.apply(
            StatsFilter(accounts: ["acct-1"], models: ["claude-fable-5-1"]),
            to: Self.sample)
        #expect(selection.drawn.map(\.id) == ["b"])
    }

    @Test func aFilterMatchingNothingLeavesEmptyTotals() {
        let selection = StatsSelection.apply(StatsFilter(models: ["claude-haiku-4-5"]),
                                             to: Self.sample)
        #expect(selection.drawn.isEmpty)
        #expect(selection.totals.tokens == 0)
        #expect(selection.accounts.isEmpty)
        // The menus still offer everything, or a filter could never be switched back off.
        #expect(selection.allModels.count == 2)
        #expect(selection.allAccounts.count == 2)
    }

    /// The chart is what is capped, not the arithmetic.
    @Test func linesBeyondTheCapAreCountedButStillTotalled() {
        let many = (0..<(StatsSelection.maxLines + 5)).map { index in
            Self.series("s\(index)", session: "sess-\(index)", input: 100)
        }
        let selection = StatsSelection.apply(StatsFilter(), to: Self.response(many,
            accounts: [UsageAccountTotals(accountID: "acct-1", accountLabel: "Work",
                                          kind: .subscription,
                                          totals: Self.totals(100 * many.count))]))
        #expect(selection.drawn.count == StatsSelection.maxLines)
        #expect(selection.matchedCount == StatsSelection.maxLines + 5)
        #expect(selection.totals.input == 100 * many.count)
    }

    @Test func aLineNamesItsMacOnlyWhenThereIsMoreThanOne() {
        let fleet = StatsSelection.apply(StatsFilter(), to: Self.sample)
        #expect(fleet.multipleMachines)
        #expect(StatsSelection.label(fleet.drawn[0], machines: true)
            == "api-gateway · opus-5 · studio")
        #expect(StatsSelection.label(fleet.drawn[0], machines: false)
            == "api-gateway · opus-5")

        let alone = StatsSelection.apply(StatsFilter(), to: Self.response(
            [Self.series("a", input: 1)], accounts: []))
        #expect(!alone.multipleMachines)
    }

    /// A session that moved account mid-range is two lines, and two legend rows reading
    /// the same thing would be worse than none.
    @Test func aLineNamesItsAccountOnlyWhenAnotherSharesItsName() {
        let response = Self.response([
            Self.series("a", account: "acct-A", label: "Work", input: 200),
            Self.series("b", account: "acct-B", label: "Personal", input: 100),
            Self.series("c", session: "sess-2", name: "batch", input: 50),
        ], accounts: [])
        let selection = StatsSelection.apply(StatsFilter(), to: response)
        #expect(selection.label(selection.drawn[0]) == "api-gateway · opus-5 · Work")
        #expect(selection.label(selection.drawn[1]) == "api-gateway · opus-5 · Personal")
        // The one that shares its name with nothing stays short.
        #expect(selection.label(selection.drawn[2]) == "batch · opus-5")
    }

    @Test func anUnpricedModelIsCarriedIntoTheTotals() {
        let response = Self.response([
            Self.series("a", input: 100),
            Self.series("b", session: "sess-2", model: "claude-unheard-of-9", input: 50,
                        unpriced: ["claude-unheard-of-9"]),
        ], accounts: [UsageAccountTotals(accountID: "acct-1", accountLabel: "Work",
                                         kind: .subscription, totals: Self.totals(150))])
        let selection = StatsSelection.apply(StatsFilter(), to: response)
        #expect(selection.totals.unpricedModels == ["claude-unheard-of-9"])
        #expect(selection.accounts.first?.totals.unpricedModels == ["claude-unheard-of-9"])
    }

    /// The readout names the span a point covers, not the pixel under the pointer — and
    /// it is the same arithmetic the ledger uses to decide which minute a request landed
    /// in, which is the rule the whole upsert-instead-of-add story depends on.
    @Test func aHoverSnapsDownToItsBucket() {
        let inside = Self.noon.addingTimeInterval(137)
        #expect(UsageGrid.floor(inside, seconds: 300) == Self.noon)
        #expect(UsageGrid.floor(Self.noon.addingTimeInterval(301), seconds: 300)
            == Self.noon.addingTimeInterval(300))
        #expect(UsageGrid.floor(inside, seconds: 0) == nil)
        #expect(UsageGrid.minute(containing: inside)
            == Self.noon.addingTimeInterval(120))
        #expect(UsageLedger.minute(containing: inside)
            == UsageGrid.floor(inside, seconds: 60))
    }

    @Test func tokenCountsAreShortenedForReading() {
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1_500) == "1.5k")
        #expect(Format.tokens(2_400_000) == "2.4M")
        #expect(Format.tokens(0) == "0")
    }

    @Test func aModelNameDropsItsSharedPrefix() {
        #expect(StatsSelection.shortModel("claude-fable-5-1") == "fable-5-1")
        #expect(StatsSelection.shortModel("something-else") == "something-else")
    }
}
