import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Reset header is only ever shortened")
struct ResetClampTests {
    static let name = "anthropic-ratelimit-unified-reset"

    static func stamp(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

    /// The rewrite exists to shorten an over-long wait using knowledge upstream lacks.
    @Test func aNearerResetReplacesAFarOne() throws {
        let now = Date()
        let upstream = now.addingTimeInterval(3 * 86400)
        let soonest = now.addingTimeInterval(4 * 3600)
        let out = try #require(SessionProxy.shorteningReset(
            [(Self.name, Self.stamp(upstream)), ("content-type", "application/json")],
            to: soonest, now: now))
        #expect(out.first { $0.0 == Self.name }?.1 == Self.stamp(soonest))
        #expect(out.contains { $0.0 == "content-type" })
        #expect(out.filter { $0.0 == Self.name }.count == 1)
    }

    /// ccmux's view of a per-model weekly window goes stale — those windows never appear
    /// in response headers — and `availableAt` answers "now" when it sees nothing blocked.
    /// Writing that over a correct far-future reset would make Claude Code retry
    /// immediately, forever, burning a request on every account each cycle.
    @Test func anImmediateAnswerIsIgnoredRatherThanWritten() {
        let now = Date()
        let upstream = now.addingTimeInterval(3 * 86400)
        #expect(SessionProxy.shorteningReset([(Self.name, Self.stamp(upstream))],
                                             to: now, now: now) == nil)
        #expect(SessionProxy.shorteningReset([(Self.name, Self.stamp(upstream))],
                                             to: now.addingTimeInterval(-60), now: now) == nil)
        #expect(SessionProxy.shorteningReset([(Self.name, Self.stamp(upstream))],
                                             to: now.addingTimeInterval(5), now: now) == nil)
    }

    /// It must never make Claude Code wait *longer* than the server said.
    @Test func aLaterResetIsNeverWritten() {
        let now = Date()
        let upstream = now.addingTimeInterval(2 * 3600)
        #expect(SessionProxy.shorteningReset([(Self.name, Self.stamp(upstream))],
                                             to: now.addingTimeInterval(3 * 3600),
                                             now: now) == nil)
    }

    @Test func aRefusalWithNoResetHeaderStillGetsOne() throws {
        let now = Date()
        let soonest = now.addingTimeInterval(4 * 3600)
        let out = try #require(SessionProxy.shorteningReset([("x", "y")], to: soonest,
                                                            now: now))
        #expect(out.first { $0.0 == Self.name }?.1 == Self.stamp(soonest))
    }
}

@Suite("Settings survive an upgrade")
struct SettingsMigrationTests {
    /// Synthesized decoding requires every key, so a settings file written before a field
    /// existed used to fail wholesale and reset every setting to defaults — silently
    /// turning `autoSwitch: off` back into `immediate`.
    @Test func aFileMissingNewKeysKeepsTheSettingsItDoesHave() throws {
        let old = Data("""
        {"warnThresholdPercent":7,"watchedWindows":["session"],"autoSwitch":"off",
         "notifyOnAutoSwitch":false,"notifyOnReloginNeeded":true,
         "mutedAccountIDs":["acct-1"],
         "policies":[{"name":"opus","requiredWindows":["session","weeklyAll"]}]}
        """.utf8)
        let settings = try JSONStore.decoder.decode(Settings.self, from: old)
        #expect(settings.autoSwitch == .off)
        #expect(settings.warnThresholdPercent == 7)
        #expect(settings.mutedAccountIDs == ["acct-1"])
        // Fields the old file never knew about come back as defaults, not as a reset.
        #expect(settings.keepWindowsRolling)
        #expect(settings.policies.first?.launchFloors.isEmpty == true)
    }

    @Test func anEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONStore.decoder.decode(Settings.self, from: Data("{}".utf8))
        #expect(settings == Settings())
    }

    @Test func aFullRoundTripIsLossless() throws {
        var settings = Settings()
        settings.autoSwitch = .atTurnBoundary
        settings.keepWindowsRolling = false
        settings.warnThresholdPercent = 12
        let data = try JSONStore.encoder.encode(settings)
        #expect(try JSONStore.decoder.decode(Settings.self, from: data) == settings)
    }
}

@Suite("Model identification")
struct ModelIdentificationTests {
    /// A display name with a version ("Sonnet 4.5") has to match `claude-sonnet-4-5`.
    @Test func separatorsAndCaseDoNotBreakMatching() {
        let window = UsageWindow(kind: .weeklyScoped, label: "w", percent: 0,
                                 modelName: "Sonnet 4.5")
        #expect(ModelRouting.window(window, governs: "claude-sonnet-4-5"))
        #expect(!ModelRouting.window(window, governs: "claude-opus-5"))
    }

    /// A very short display name must not match every model id.
    @Test func aTooShortNameIsIgnored() {
        let window = UsageWindow(kind: .weeklyScoped, label: "w", percent: 0, modelName: "5")
        #expect(!ModelRouting.window(window, governs: "claude-fable-5"))
    }

    /// Losing the model on a large body would silently drop model-scoped eligibility, so
    /// there is a prefix scan for bodies too big to be worth parsing.
    @Test func theModelIsFoundInABodyTooLargeToParse() {
        let filler = String(repeating: "x", count: 5 * 1024 * 1024)
        let body = Data(#"{"model":"claude-fable-5","messages":[{"role":"user","content":"#
                        .utf8) + Data("\"\(filler)\"}]}".utf8)
        #expect(body.count > 4 * 1024 * 1024)
        #expect(ModelRouting.model(inRequestBody: body) == "claude-fable-5")
    }

    @Test func theePrefixScanToleratesWhitespaceAndMissingFields() {
        #expect(ModelRouting.modelFromPrefix(Data(#"{ "model" : "claude-opus-5" }"#.utf8))
                == "claude-opus-5")
        #expect(ModelRouting.modelFromPrefix(Data(#"{"max_tokens":1}"#.utf8)) == nil)
        #expect(ModelRouting.modelFromPrefix(Data(#"{"model":""}"#.utf8)) == nil)
    }
}
