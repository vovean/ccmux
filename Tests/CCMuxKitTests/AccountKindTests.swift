import Foundation
import Testing
@testable import CCMuxKit

@Suite("Rotation and account kind")
struct RotationTests {
    private func account(_ id: String, kind: AccountKind = .subscription,
                         inRotation: Bool = true) -> Account {
        Account(id: id, label: id, kind: kind, inRotation: inRotation)
    }

    @Test("Only in-rotation subscriptions may be chosen automatically")
    func autoAssignability() {
        #expect(account("a").isAutoAssignable)
        #expect(account("b", inRotation: false).isAutoAssignable == false)
        // Spending money is always an explicit decision, so a key is never auto-picked
        // even when it is nominally in rotation.
        #expect(account("c", kind: .apiKey).isAutoAssignable == false)
        #expect(account("d", kind: .apiKey, inRotation: false).isAutoAssignable == false)
    }

    @Test("An account added before these fields existed still decodes")
    func decodesLegacyAccount() throws {
        let legacy = """
        {"id":"x","label":"old","priority":3,"health":"ok",
         "addedAt":760000000,"subscriptionType":"team"}
        """
        let decoded = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))
        #expect(decoded.id == "x")
        #expect(decoded.kind == .subscription)
        #expect(decoded.inRotation, "an existing account must not silently leave rotation")
        #expect(decoded.spendLifetimeUSD == 0)
        #expect(decoded.monthlyBudgetUSD == nil)
    }

    @Test("A session record written before spend tracking still decodes")
    func decodesLegacySession() throws {
        let legacy = """
        {"id":"s","pid":42,"port":9000,"accountID":"a","policyName":"opus",
         "cwd":"/tmp","startedAt":760000000}
        """
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: Data(legacy.utf8))
        #expect(decoded.pid == 42)
        #expect(decoded.spendUSD == 0)
    }
}

@Suite("Monthly spend")
struct MonthlySpendTests {
    @Test("A new month resets the running total rather than carrying it")
    func rollsOverByMonth() {
        let august = Date(timeIntervalSince1970: 1_787_500_000)   // 2026-08
        var spend = MonthlySpend(month: MonthlySpend.monthKey(august), amountUSD: 12)
        #expect(spend.amount(inMonthOf: august) == 12)

        let laterMonth = august.addingTimeInterval(45 * 86_400)
        #expect(spend.amount(inMonthOf: laterMonth) == 0, "a stale month reads as zero")

        spend.add(3, on: laterMonth)
        #expect(spend.amountUSD == 3, "the stale amount is replaced, not added to")
        #expect(spend.month == MonthlySpend.monthKey(laterMonth))
    }
}

@Suite("Cost")
struct PricingTests {
    @Test("Model ids are matched past their decorations")
    func normalization() {
        #expect(Pricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(Pricing.normalize("claude-fable-5[1m]") == "claude-fable-5")
        #expect(Pricing.normalize("claude-opus-5") == "claude-opus-5")
    }

    @Test("Cost combines input, output and both cache rates")
    func costMaths() throws {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000,
                               cacheRead: 1_000_000, cacheWrite5m: 1_000_000)
        let cost = try #require(Pricing.cost(model: "claude-opus-5", usage: usage))
        // 5 input + 25 output + 0.5 cache read + 6.25 cache write
        #expect(abs(cost - 36.75) < 0.0001)
    }

    @Test("Sonnet 5 intro pricing applies only until it lapses")
    func introPricing() throws {
        let usage = TokenUsage(input: 1_000_000)
        let during = try #require(Pricing.day("2026-08-24"))
        let after = try #require(Pricing.day("2026-10-01"))
        #expect(Pricing.cost(model: "claude-sonnet-5", usage: usage, on: during) == 2)
        #expect(Pricing.cost(model: "claude-sonnet-5", usage: usage, on: after) == 3)
    }

    /// A wrong number is worse than no number, so an unrecognised model reports nothing
    /// rather than being guessed at.
    @Test("An unknown model yields no cost")
    func unknownModel() {
        #expect(Pricing.cost(model: "claude-something-new", usage: TokenUsage(input: 100)) == nil)
    }
}
