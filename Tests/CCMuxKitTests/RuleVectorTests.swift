import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// The other half of the ranking contract.
///
/// Which account serves a request, when one frees up, and how the two usage sources fold
/// together are all implemented twice: here, and in the Linux agent's Go. Nothing either
/// compiler does can notice the two drifting apart — it would surface as a headless box
/// draining a different account from the Macs beside it, or as a run refused while an
/// account had headroom.
///
/// These vectors are emitted by the agent's own implementation
/// (agent/internal/rules/vectors_test.go) and asserted here against ours.
///
/// When a rule changes: `UPDATE_FIXTURES=1 go test ./internal/rules/` in agent/, then
/// make sure this suite still passes.
@Suite("Rule vectors")
struct RuleVectorTests {
    // MARK: - the vector shapes

    struct VectorAccount: Decodable {
        var id: String
        var label: String
        var kind: AccountKind
        var health: AccountHealth

        var account: Account {
            Account(id: id, label: label, health: health, kind: kind)
        }
    }

    struct VectorSnapshot: Decodable {
        var windows: [UsageWindow]
        var fetchedAt: Date
        var lastEndpointFetchAt: Date?

        var snapshot: UsageSnapshot {
            UsageSnapshot(windows: windows, fetchedAt: fetchedAt,
                          lastEndpointFetchAt: lastEndpointFetchAt)
        }
    }

    struct VectorHeader: Decodable {
        var name: String
        var value: String
    }

    struct Cases<Case: Decodable>: Decodable { var cases: [Case] }

    static func load<Case: Decodable>(_ name: String, _ type: Case.Type) throws -> [Case] {
        // #filePath is Tests/CCMuxKitTests/…; the vectors live beside the Go agent.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CCMuxKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("agent/testdata/rules/\(name)")
        let data = try Data(contentsOf: url)
        return try JSONStore.decoder.decode(Cases<Case>.self, from: data).cases
    }

    static func snapshots(_ raw: [String: VectorSnapshot]) -> [String: UsageSnapshot] {
        raw.mapValues(\.snapshot)
    }

    // MARK: - ranking

    struct RankCase: Decodable {
        var name: String
        var model: String
        var accounts: [VectorAccount]
        var usage: [String: VectorSnapshot]
        var excluded: [String]?
        var expectedOrder: [String]?
        var expectedCanServe: [String: Bool]
    }

    @Test func rankingAgrees() throws {
        let cases = try Self.load("ranking.json", RankCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let accounts = vector.accounts.map(\.account)
            let usage = Self.snapshots(vector.usage)
            let ranked = ModelRouting.rankLeastRemaining(
                vector.model, accounts: accounts, usage: usage,
                excluding: Set(vector.excluded ?? []))
            #expect(ranked.map(\.id) == (vector.expectedOrder ?? []),
                    "ranking disagrees: \(vector.name)")
            for account in accounts {
                let canServe = ModelRouting.canServe(vector.model, usage: usage[account.id])
                #expect(canServe == vector.expectedCanServe[account.id],
                        "eligibility of \(account.id) disagrees: \(vector.name)")
            }
        }
    }

    // MARK: - availability

    struct AvailabilityCase: Decodable {
        var name: String
        var model: String
        var now: Date
        var accounts: [VectorAccount]
        var usage: [String: VectorSnapshot]
        var expectedAvailableAt: [String: Date]
        var expectedUnknowable: [String]?
        var expectedSoonestAccountID: String?
        var expectedSoonestAt: Date?
    }

    @Test func availabilityAgrees() throws {
        let cases = try Self.load("availability.json", AvailabilityCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let accounts = vector.accounts.map(\.account)
            let usage = Self.snapshots(vector.usage)
            let unknowable = Set(vector.expectedUnknowable ?? [])
            for account in accounts {
                let at = ModelRouting.availableAt(vector.model, usage: usage[account.id],
                                                  now: vector.now)
                if unknowable.contains(account.id) {
                    #expect(at == nil,
                            "\(account.id) should be unknowable: \(vector.name)")
                } else {
                    #expect(at == vector.expectedAvailableAt[account.id],
                            "availability of \(account.id) disagrees: \(vector.name)")
                }
            }
            let soonest = ModelRouting.soonestAvailable(vector.model, accounts: accounts,
                                                        usage: usage, now: vector.now)
            #expect(soonest?.accountID == vector.expectedSoonestAccountID,
                    "soonest account disagrees: \(vector.name)")
            #expect(soonest?.at == vector.expectedSoonestAt,
                    "soonest moment disagrees: \(vector.name)")
            #expect((soonest == nil) == (vector.expectedSoonestAccountID == nil),
                    "one side found a soonest and the other did not: \(vector.name)")
        }
    }

    // MARK: - folding

    struct FoldCase: Decodable {
        var name: String
        var previous: VectorSnapshot?
        var windows: [UsageWindow]
        var observedAt: Date
        var expected: VectorSnapshot
    }

    @Test func endpointFoldingAgrees() throws {
        let cases = try Self.load("folding.json", FoldCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let folded = UsageSnapshot.folding(vector.windows,
                                               into: vector.previous?.snapshot,
                                               observedAt: vector.observedAt)
            #expect(folded.windows == vector.expected.windows,
                    "folded windows disagree: \(vector.name)")
            #expect(folded.fetchedAt == vector.expected.fetchedAt,
                    "fetchedAt disagrees: \(vector.name)")
            #expect(folded.lastEndpointFetchAt == vector.expected.lastEndpointFetchAt,
                    "lastEndpointFetchAt disagrees: \(vector.name)")
        }
    }

    // MARK: - folding response headers

    @Test func headerFoldingAgrees() throws {
        let cases = try Self.load("header-folding.json", FoldCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            // What Engine.record does with the windows it reads off a response: an
            // upsert by window id, and nothing at all when the response carried none.
            var snapshot = vector.previous?.snapshot ?? UsageSnapshot(windows: [],
                                                                      fetchedAt: vector.observedAt)
            if !vector.windows.isEmpty {
                for window in vector.windows { snapshot.windows.upsert(window) }
                snapshot.fetchedAt = vector.observedAt
            }
            #expect(snapshot.windows == vector.expected.windows,
                    "folded windows disagree: \(vector.name)")
            #expect(snapshot.fetchedAt == vector.expected.fetchedAt,
                    "fetchedAt disagrees: \(vector.name)")
        }
    }

    // MARK: - response headers

    struct HeaderCase: Decodable {
        var name: String
        var headers: [String: String]
        var statusCode: Int
        var expectedWindows: [UsageWindow]?
        var expectedRateLimited: Bool
    }

    @Test func headerParsingAgrees() throws {
        let cases = try Self.load("headers.json", HeaderCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let windows = UsageParser.windowsFromResponseHeaders(vector.headers)
            #expect(windows == (vector.expectedWindows ?? []),
                    "header windows disagree: \(vector.name)")
            let limited = UsageParser.isRateLimited(headers: vector.headers,
                                                    statusCode: vector.statusCode)
            #expect(limited == vector.expectedRateLimited,
                    "rate-limit verdict disagrees: \(vector.name)")
        }
    }

    // MARK: - shortening the reset

    struct ResetCase: Decodable {
        var name: String
        var headers: [VectorHeader]
        var to: Date
        var now: Date
        var changed: Bool
        var expected: [VectorHeader]?
    }

    @Test func resetShorteningAgrees() throws {
        let cases = try Self.load("reset.json", ResetCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let input = vector.headers.map { ($0.name, $0.value) }
            let out = SessionProxy.shorteningReset(input, to: vector.to, now: vector.now)
            #expect((out != nil) == vector.changed,
                    "rewrite verdict disagrees: \(vector.name)")
            guard let out, let expected = vector.expected else { continue }
            #expect(out.map(\.0) == expected.map(\.name),
                    "rewritten header names disagree: \(vector.name)")
            #expect(out.map(\.1) == expected.map(\.value),
                    "rewritten header values disagree: \(vector.name)")
        }
    }

    // MARK: - prices

    struct PriceCase: Decodable {
        var name: String
        var model: String
        var at: Date
        var usage: VectorUsage
        var priced: Bool
        var costUSD: Double
        var normalized: String
    }

    struct VectorUsage: Decodable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite5m: Int
        var cacheWrite1h: Int

        var tokens: TokenUsage {
            TokenUsage(input: input, output: output, cacheRead: cacheRead,
                       cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
        }
    }

    /// A figure that disagrees between the two tables misbooks real money on the Stats
    /// page, and the model-id resolution is the subtle half: a dated snapshot inherits
    /// its parent's price, a point release must not.
    @Test func pricingAgrees() throws {
        let cases = try Self.load("pricing.json", PriceCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            #expect(Pricing.normalize(vector.model) == vector.normalized,
                    "model resolution disagrees: \(vector.name)")
            let cost = Pricing.cost(model: vector.model, usage: vector.usage.tokens,
                                    on: vector.at)
            #expect((cost != nil) == vector.priced,
                    "one side priced it and the other did not: \(vector.name)")
            guard let cost else { continue }
            // Not exact equality: the two compilers fuse multiply-add differently on
            // arm64, so the last bit can differ (0.04875 against 0.04875000000000001).
            // A divergence that matters — a wrong rate in one of the two tables — is
            // some percent, which is fourteen orders of magnitude above this.
            let tolerance = max(1e-9, abs(vector.costUSD) * 1e-9)
            #expect(abs(cost - vector.costUSD) <= tolerance,
                    "price disagrees: \(vector.name) — \(cost) against \(vector.costUSD)")
        }
    }

    // MARK: - which model a scoped window governs

    struct ScopeCase: Decodable {
        var name: String
        var modelName: String
        var modelID: String
        var expected: Bool
    }

    @Test func scopedWindowMatchingAgrees() throws {
        let cases = try Self.load("scoping.json", ScopeCase.self)
        #expect(!cases.isEmpty)
        for vector in cases {
            let window = UsageWindow(kind: .weeklyScoped, label: "Weekly \(vector.modelName)",
                                     percent: 0, modelName: vector.modelName)
            #expect(ModelRouting.window(window, governs: vector.modelID) == vector.expected,
                    "scope matching disagrees: \(vector.name)")
        }
    }
}
