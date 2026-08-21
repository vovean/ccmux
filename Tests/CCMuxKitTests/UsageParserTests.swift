import Foundation
import Testing
@testable import CCMuxKit

@Suite("Usage parsing")
struct UsageParserTests {
    /// Captured verbatim from GET /api/oauth/usage on a live subscription, trimmed to
    /// the fields the parser reads.
    static let realResponse = """
    {
      "five_hour": {"utilization": 36.0, "resets_at": "2026-08-21T23:30:00.222440+00:00"},
      "seven_day": {"utilization": 71.0, "resets_at": "2026-08-25T10:00:00.222467+00:00"},
      "seven_day_opus": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 36, "severity": "normal",
         "resets_at": "2026-08-21T23:30:00.222440+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 71, "severity": "normal",
         "resets_at": "2026-08-25T10:00:00.222467+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 60, "severity": "normal",
         "resets_at": "2026-08-25T10:00:00.222763+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ]
    }
    """

    static func parse(_ json: String) throws -> [UsageWindow] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return UsageParser.windows(from: try #require(object as? [String: Any]))
    }

    @Test func parsesRealUsageResponse() throws {
        let windows = try Self.parse(Self.realResponse)
        #expect(windows.count == 3)

        let session = try #require(windows.first { $0.kind == .session })
        #expect(session.percent == 36)
        #expect(session.headroom == 64)

        let weekly = try #require(windows.first { $0.kind == .weeklyAll })
        #expect(weekly.percent == 71)

        let fable = try #require(windows.first { $0.kind == .weeklyScoped })
        #expect(fable.modelName == "Fable")
        #expect(fable.percent == 60)
        #expect(fable.label == "Weekly Fable")
        #expect(fable.resetsAt != nil)
    }

    /// The per-model window is the whole point of the fable policy, so a response
    /// carrying only the legacy keys must not silently look like a full picture.
    @Test func fallsBackToLegacyKeysWhenLimitsAbsent() throws {
        let windows = try Self.parse("""
        {"five_hour": {"utilization": 12.5, "resets_at": "2026-08-21T23:30:00Z"},
         "seven_day": {"utilization": 40.0, "resets_at": null}}
        """)
        #expect(windows.map(\.kind) == [.session, .weeklyAll])
        #expect(windows[0].percent == 12.5)
        #expect(windows[1].resetsAt == nil)
    }

    @Test func emptyResponseYieldsNoWindows() throws {
        #expect(try Self.parse("{}").isEmpty)
        #expect(try Self.parse(#"{"limits": []}"#).isEmpty)
    }

    @Test func unknownLimitKindIsKeptRatherThanDropped() throws {
        let windows = try Self.parse("""
        {"limits": [{"kind": "monthly_something", "percent": 5, "resets_at": null}]}
        """)
        #expect(windows.count == 1)
        #expect(windows[0].kind == .other)
        #expect(windows[0].label == "Monthly something")
    }

    @Test func scopedLimitWithoutModelNameIsSkipped() throws {
        let windows = try Self.parse("""
        {"limits": [{"kind": "weekly_scoped", "percent": 5, "scope": {"model": null}}]}
        """)
        #expect(windows.isEmpty)
    }

    /// Captured from a real /v1/messages response. The header is a fraction, not a
    /// percentage — reading 0.35 as 35% headroom instead of 35% used would invert the
    /// whole notification logic.
    @Test func parsesRateLimitResponseHeaders() throws {
        let windows = UsageParser.windowsFromResponseHeaders([
            "anthropic-ratelimit-unified-status": "allowed",
            "anthropic-ratelimit-unified-5h-status": "allowed",
            "anthropic-ratelimit-unified-5h-reset": "1787355000",
            "anthropic-ratelimit-unified-5h-utilization": "0.35",
            "anthropic-ratelimit-unified-7d-status": "allowed",
            "anthropic-ratelimit-unified-7d-reset": "1787652000",
            "anthropic-ratelimit-unified-7d-utilization": "0.7",
        ])
        #expect(windows.count == 2)
        let session = try #require(windows.first { $0.kind == .session })
        #expect(abs(session.percent - 35) < 0.001)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1787355000))
        let weekly = try #require(windows.first { $0.kind == .weeklyAll })
        #expect(abs(weekly.percent - 70) < 0.001)
    }

    @Test func headerParsingIsCaseInsensitiveAndTolerantOfAbsence() {
        #expect(UsageParser.windowsFromResponseHeaders([:]).isEmpty)
        let windows = UsageParser.windowsFromResponseHeaders([
            "Anthropic-RateLimit-Unified-5h-Utilization": "0.5",
        ])
        #expect(windows.count == 1)
        #expect(windows[0].percent == 50)
        #expect(windows[0].resetsAt == nil)
    }

    @Test func detectsRateLimitRejection() {
        #expect(UsageParser.isRateLimited(headers: [:], statusCode: 429))
        #expect(UsageParser.isRateLimited(
            headers: ["anthropic-ratelimit-unified-status": "rejected"], statusCode: 200))
        #expect(!UsageParser.isRateLimited(
            headers: ["anthropic-ratelimit-unified-status": "allowed"], statusCode: 200))
    }
}
