import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Reset countdowns")
struct UsageCountdownTests {
    /// Midday local, so that ±1h stays inside the same calendar day and −26h is reliably
    /// the day before, whatever zone the tests run in.
    private static let reset: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 1; parts.hour = 12; parts.minute = 0
        return Calendar.current.date(from: parts)!
    }()

    private func window(percent: Double, resetsAt: Date?) -> UsageWindow {
        UsageWindow(kind: .weeklyAll, label: "Weekly", percent: percent,
                    resetsAt: resetsAt, modelName: nil)
    }

    /// The bug, exactly as it appeared: an account pinned at 100% produces an identical
    /// window on every poll, so a countdown that reads the clock ambiently has nothing to
    /// redraw from and freezes. It showed "3h 14m" beside a pooled summary that correctly
    /// said 54m — and the frozen one was the exhausted account, the single row where when
    /// it comes back is the whole question.
    @Test func theCountdownAdvancesForAWindowThatNeverChanges() {
        let stuck = window(percent: 100, resetsAt: Self.reset)
        let early = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-3 * 3600))
        let late = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-50 * 60))
        #expect(early != late)
        #expect(early?.hasPrefix("3h 0m") == true)
        #expect(late?.hasPrefix("50m") == true)
    }

    /// Only the countdown moves. The clock half names a fixed instant, so a bar redrawing
    /// every thirty seconds must not appear to be changing when it reset.
    @Test func theClockHalfStaysPutWhileTheCountdownMoves() {
        let stuck = window(percent: 100, resetsAt: Self.reset)
        let early = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-7200))
        let late = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-600))
        let clockHalf = { (text: String?) in
            text?.split(separator: "·").last?.trimmingCharacters(in: .whitespaces)
        }
        #expect(clockHalf(early) == clockHalf(late))
        // Compared against the same instant it was rendered from. Comparing against an
        // ambient `Format.clock(reset)` would hold no matter what the code did, which is
        // what this assertion used to do.
        #expect(clockHalf(early)
            == Format.clock(Self.reset, now: Self.reset.addingTimeInterval(-7200)))
    }

    /// Both halves must come from one instant. `Format.clock` date-qualifies anything not
    /// happening today, so a clock read separately from the countdown means that just
    /// after midnight the two disagree about which day it is and a reset at 23:59 renders
    /// as a dated tomorrow.
    @Test func theClockHalfIsMeasuredFromTheInjectedInstantToo() {
        let stuck = window(percent: 100, resetsAt: Self.reset)
        let hourBefore = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-3600))
        let dayBefore = UsageBar.resetText(stuck, now: Self.reset.addingTimeInterval(-26 * 3600))
        // Same reset seen from two days: one bare time, one date-qualified. Reading the
        // machine clock would render both the same and hide the split entirely.
        #expect(hourBefore != dayBefore)
        #expect(dayBefore?.contains(
            Format.clock(Self.reset, now: Self.reset.addingTimeInterval(-26 * 3600))) == true)
    }

    /// A window with no reset renders no trailing text at all, rather than a countdown to
    /// nothing — the 5-hour window of an idle account arrives exactly like this.
    @Test func aWindowWithNoResetRendersNothing() {
        #expect(UsageBar.resetText(window(percent: 0, resetsAt: nil), now: Date()) == nil)
    }

    /// A reset already in the past reads as due rather than counting upwards.
    @Test func aResetThatHasPassedDoesNotRunBackwards() {
        let past = window(percent: 100, resetsAt: Self.reset)
        let text = UsageBar.resetText(past, now: Self.reset.addingTimeInterval(600))
        #expect(text?.hasPrefix("0m") == true)
    }

    /// What the summary and the per-account row must agree on: given one instant, the
    /// soonest pooled reset is the same reset the owning account's own row counts down to.
    /// They disagreed by hours in the field, and only because they were measured from
    /// different moments.
    @Test func theSummaryAndTheOwningAccountAgreeAtOneInstant() throws {
        let now = Self.reset.addingTimeInterval(-50 * 60)
        let spent = Account(id: "a", label: "spent", health: .ok, kind: .subscription)
        let roomy = Account(id: "b", label: "roomy", health: .ok, kind: .subscription)
        let summary = UsageSummaries.build(
            accounts: [spent, roomy],
            usage: [
                "a": UsageSnapshot(windows: [window(percent: 100, resetsAt: Self.reset)],
                                   fetchedAt: now),
                "b": UsageSnapshot(windows: [window(percent: 10,
                                                    resetsAt: Self.reset
                                                        .addingTimeInterval(86_400))],
                                   fetchedAt: now),
            ],
            now: now)
        let row = try #require(summary.rows.first)
        #expect(row.nearestReset == Self.reset)
        #expect(Format.countdown(to: Self.reset, from: now) == "50m")
        #expect(UsageBar.resetText(window(percent: 100, resetsAt: Self.reset), now: now)?
            .hasPrefix("50m") == true)
    }
}
