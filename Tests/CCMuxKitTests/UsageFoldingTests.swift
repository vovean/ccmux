import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// Two sources write these numbers. Response headers refresh the 5-hour and weekly
/// windows within seconds of every request; the usage endpoint answers with per-model
/// windows and, for a delegated account, from a cache that can be minutes old. Folding is
/// what stops the late one dragging the fresh ones backwards.
@Suite("Usage folding")
struct UsageFoldingTests {
    static let noon = Date(timeIntervalSince1970: 1_789_000_000)

    static func window(_ kind: UsageWindow.Kind, _ percent: Double,
                       model: String? = nil) -> UsageWindow {
        UsageWindow(kind: kind, label: model.map { "Weekly \($0)" } ?? kind.rawValue,
                    percent: percent, resetsAt: noon.addingTimeInterval(3600),
                    modelName: model)
    }

    /// The reported symptom: a poll answered from a ten-minute-old cache, landing on a
    /// figure the headers had already moved past.
    @Test func aLateAnswerDoesNotLowerAHeaderFreshWindow() {
        let held = UsageSnapshot(windows: [Self.window(.session, 36)],
                                 fetchedAt: Self.noon,
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-600))
        let folded = UsageSnapshot.folding([Self.window(.session, 27)], into: held,
                                           observedAt: Self.noon.addingTimeInterval(-280))
        #expect(folded.windows(kind: .session).first?.percent == 36)
        #expect(folded.fetchedAt == Self.noon)
    }

    /// It is still the only source for the per-model windows, so those it may set.
    @Test func aLateAnswerStillCarriesTheWindowsOnlyItReports() {
        let held = UsageSnapshot(windows: [Self.window(.session, 36)],
                                 fetchedAt: Self.noon,
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-600))
        let folded = UsageSnapshot.folding(
            [Self.window(.session, 27), Self.window(.weeklyScoped, 17, model: "Fable")],
            into: held, observedAt: Self.noon.addingTimeInterval(-280))
        #expect(folded.windows(kind: .session).first?.percent == 36)
        #expect(folded.windows(kind: .weeklyScoped, model: "Fable").first?.percent == 17)
        // The endpoint stamp moves even though the snapshot's own stamp does not, or the
        // poller would think it had never read the endpoint and never back off.
        #expect(folded.lastEndpointFetchAt == Self.noon.addingTimeInterval(-280))
    }

    /// The endpoint owns whether its own windows exist. Holding one it has stopped
    /// reporting pins that model at its last percent, and `ModelRouting` then fails every
    /// request for it off a healthy account with nothing able to clear it.
    @Test func aLateAnswerDropsAPerModelWindowItNoLongerReports() {
        let held = UsageSnapshot(windows: [Self.window(.session, 36),
                                           Self.window(.weeklyScoped, 100, model: "Fable")],
                                 fetchedAt: Self.noon,
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-600))
        let folded = UsageSnapshot.folding([Self.window(.session, 27)], into: held,
                                           observedAt: Self.noon.addingTimeInterval(-280))
        #expect(folded.windows(kind: .weeklyScoped).isEmpty)
        // And the header-fresh one is still untouched by the late answer.
        #expect(folded.windows(kind: .session).first?.percent == 36)
    }

    /// The real sequence: the poll runs every few minutes for the life of a session.
    @Test func foldingRepeatedlyDoesNotAccumulate() {
        var held = UsageSnapshot(windows: [Self.window(.session, 36)],
                                 fetchedAt: Self.noon,
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-900))
        for step in 1...3 {
            held = UsageSnapshot.folding(
                [Self.window(.session, 27),
                 Self.window(.weeklyScoped, Double(step * 10), model: "Fable")],
                into: held, observedAt: Self.noon.addingTimeInterval(Double(-400 + step)))
        }
        #expect(held.windows.count == 2)
        #expect(held.windows(kind: .session).first?.percent == 36)
        #expect(held.windows(kind: .weeklyScoped, model: "Fable").first?.percent == 30)
    }

    /// Older than the last endpoint read as well, so it knows nothing newer at all.
    @Test func anAnswerOlderThanTheLastEndpointReadChangesNothing() {
        let held = UsageSnapshot(windows: [Self.window(.session, 36),
                                           Self.window(.weeklyScoped, 50, model: "Fable")],
                                 fetchedAt: Self.noon,
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-100))
        let folded = UsageSnapshot.folding(
            [Self.window(.weeklyScoped, 17, model: "Fable")],
            into: held, observedAt: Self.noon.addingTimeInterval(-400))
        #expect(folded.windows(kind: .weeklyScoped, model: "Fable").first?.percent == 50)
        #expect(folded.windows(kind: .session).first?.percent == 36)
        #expect(folded.lastEndpointFetchAt == Self.noon.addingTimeInterval(-100))
    }

    /// As fresh as anything held, so it is authoritative — including about a window the
    /// account no longer has.
    @Test func aCurrentAnswerReplacesWhatIsHeld() {
        let held = UsageSnapshot(windows: [Self.window(.session, 36),
                                           Self.window(.weeklyScoped, 50, model: "Fable")],
                                 fetchedAt: Self.noon.addingTimeInterval(-60),
                                 lastEndpointFetchAt: Self.noon.addingTimeInterval(-60))
        let folded = UsageSnapshot.folding([Self.window(.session, 99)], into: held,
                                           observedAt: Self.noon)
        #expect(folded.windows(kind: .session).first?.percent == 99)
        #expect(folded.windows(kind: .weeklyScoped).isEmpty)
        #expect(folded.fetchedAt == Self.noon)
    }

    @Test func withNothingHeldTheAnswerIsTakenWhole() {
        let folded = UsageSnapshot.folding([Self.window(.session, 12)], into: nil,
                                           observedAt: Self.noon)
        #expect(folded.windows(kind: .session).first?.percent == 12)
        #expect(folded.fetchedAt == Self.noon)
        #expect(folded.lastEndpointFetchAt == Self.noon)
    }

    /// The two halves of one fact: which windows a header can carry, and which windows
    /// the header parser actually builds. They drift apart silently otherwise.
    @Test func theHeaderParserProducesExactlyTheHeaderReportableKinds() {
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.74",
            "anthropic-ratelimit-unified-5h-reset": "1789406400",
            "anthropic-ratelimit-unified-7d-utilization": "0.11",
            "anthropic-ratelimit-unified-7d-reset": "1789524000",
        ]
        let parsed = UsageParser.windowsFromResponseHeaders(headers)
        let reportable = parsed.filter { $0.isReportedByHeaders }
        let session = parsed.filter { $0.kind == .session }
        #expect(parsed.count == 2)
        #expect(reportable.count == parsed.count)
        #expect(Set(parsed.map(\.kind)) == [.session, .weeklyAll])
        #expect(session.first?.percent == 74)
        // A per-model window is not one of them, and so may only come from the endpoint.
        #expect(!Self.window(.weeklyScoped, 1, model: "Fable").isReportedByHeaders)
    }
}
