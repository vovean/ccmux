import Foundation
import Testing
@testable import CCMuxCore
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

    /// Fable 5.1 is a new model, not a dated snapshot of Fable 5, so `normalize`
    /// deliberately declines to inherit the older entry. Without its own row it bills as
    /// unpriced and drops out of the spend figure entirely.
    @Test("Fable 5.1 is priced in its own right")
    func fable51IsPriced() throws {
        let price = try #require(Pricing.price(for: "claude-fable-5-1"))
        #expect(price.inputPerMTok == 10)
        #expect(price.outputPerMTok == 50)
        #expect(Pricing.normalize("claude-fable-5-1") == "claude-fable-5-1")
        #expect(Pricing.normalize("claude-fable-5-1[1m]") == "claude-fable-5-1")
        // The guard that made the entry necessary still holds for the next one along.
        #expect(Pricing.price(for: "claude-fable-5-2") == nil)
    }

    /// A cache read stopped being a flat tenth of input with Fable 5.1: $0.25/MTok
    /// against $10 input. The uniform multiplier would bill it at four times the rate.
    @Test("Fable 5.1 cache reads are not a tenth of input")
    func fable51CacheReads() throws {
        let usage = TokenUsage(cacheRead: 1_000_000)
        let cost = try #require(Pricing.cost(model: "claude-fable-5-1", usage: usage))
        #expect(abs(cost - 0.25) < 0.0001)
        // Fable 5 keeps the uniform tenth, so the override is per-model and not a
        // change of default.
        let older = try #require(Pricing.cost(model: "claude-fable-5", usage: usage))
        #expect(abs(older - 1.0) < 0.0001)
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

@Suite("An API-key account is actually reachable")
struct APIKeySessionTests {
    /// Assigning by hand is the only way to reach an API key, so a credential check that
    /// only understands OAuth would make the whole feature unusable.
    @Test("The placeholder credential cannot rotate or leak a lineage")
    func placeholderIsInert() {
        let placeholder = OAuthCredential.placeholderForAPIKeySession()
        #expect(placeholder.refreshToken == nil, "nothing here may rotate a lineage")
        #expect(placeholder.accessToken.hasPrefix("sk-ant") == false,
                "it must not look like, or be, a real secret")
        #expect(placeholder.isAccessTokenExpired == false,
                "an expired placeholder would make Claude Code try to refresh it")
    }
}

@Suite("Review fixes")
struct ReviewRoundFixes {
    /// A prefix match alone would bill a future "claude-sonnet-5-2" at Sonnet 5's rates,
    /// promotional pricing included, instead of admitting it is an unknown model.
    @Test("Only a dated snapshot inherits a known model's price")
    func onlyDatedSnapshotsInheritPricing() {
        #expect(Pricing.normalize("claude-sonnet-5-20260101") == "claude-sonnet-5")
        #expect(Pricing.price(for: "claude-sonnet-5-2") == nil)
        #expect(Pricing.price(for: "claude-opus-5-turbo") == nil)
        #expect(Pricing.price(for: "claude-opus-5") != nil)
    }

    /// Clear is a button. A typo must not be read as "remove my budget".
    @Test("Budget input accepts what people type and rejects the rest")
    func budgetParsing() {
        #expect(AccountsPage.parseBudget("50") == 50)
        #expect(AccountsPage.parseBudget(" $1,000 ") == 1000)
        #expect(AccountsPage.parseBudget("12.50") == 12.5)
        #expect(AccountsPage.parseBudget("") == nil)
        #expect(AccountsPage.parseBudget("abc") == nil)
        #expect(AccountsPage.parseBudget("-5") == nil)
        #expect(AccountsPage.parseBudget("0") == nil)
    }
}
