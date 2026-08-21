import Foundation
import Testing
@testable import CCMuxKit

@Suite("Usage poll cadence")
struct PollPolicyTests {
    static func snapshot(_ percent: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(kind: .session, label: "5-hour",
                                            percent: percent, resetsAt: resetsAt)])
    }

    /// The endpoint allows roughly 28-30 requests per rolling hour per token, so no
    /// path may ever schedule faster than the urgent interval.
    @Test func noPathPollsFasterThanTheUrgentInterval() {
        let cases: [(Bool, Double, Double)] = [
            (true, 0, 100), (true, 50, 50), (false, 0, 100), (false, 99, 1),
        ]
        for (inUse, before, after) in cases {
            let plan = PollPolicy.plan(isInUse: inUse, previous: Self.snapshot(before),
                                       current: Self.snapshot(after), threshold: 3)
            #expect(plan.interval >= PollPolicy.urgentInterval)
        }
    }

    @Test func idleAccountsDecayToTheLongInterval() {
        let plan = PollPolicy.plan(isInUse: false, previous: Self.snapshot(40),
                                   current: Self.snapshot(40), threshold: 3)
        #expect(plan.interval == PollPolicy.idleMaxInterval)
    }

    @Test func staticActiveAccountUsesTheActiveCeiling() {
        let plan = PollPolicy.plan(isInUse: true, previous: Self.snapshot(40),
                                   current: Self.snapshot(40), threshold: 3)
        #expect(plan.interval == PollPolicy.activeMaxInterval)
    }

    /// Urgent mode is for an account actually burning toward its limit, and is bounded
    /// because either the threshold is crossed or the movement stops.
    @Test func urgentOnlyWhenActiveNearThresholdAndMoving() {
        let urgent = PollPolicy.plan(isInUse: true, previous: Self.snapshot(88),
                                     current: Self.snapshot(94), threshold: 3)
        #expect(urgent.interval == PollPolicy.urgentInterval)

        let notMoving = PollPolicy.plan(isInUse: true, previous: Self.snapshot(94),
                                        current: Self.snapshot(94), threshold: 3)
        #expect(notMoving.interval > PollPolicy.urgentInterval)

        let notNear = PollPolicy.plan(isInUse: true, previous: Self.snapshot(10),
                                      current: Self.snapshot(30), threshold: 3)
        #expect(notNear.interval == PollPolicy.minInterval)
    }

    @Test func rateLimitedBacksOff() {
        let plan = PollPolicy.plan(isInUse: true, previous: Self.snapshot(88),
                                   current: Self.snapshot(94), threshold: 3, rateLimited: true)
        #expect(plan.interval == PollPolicy.rateLimitedBackoff)
    }

    @Test func aResetSoonPullsThePollForward() {
        let soon = Date().addingTimeInterval(90)
        let plan = PollPolicy.plan(isInUse: false, previous: Self.snapshot(40),
                                   current: Self.snapshot(40, resetsAt: soon), threshold: 3)
        #expect(plan.interval < PollPolicy.idleMaxInterval)
        #expect(plan.interval >= PollPolicy.urgentInterval)
    }

    @Test func firstFetchCountsAsMovement() {
        let plan = PollPolicy.plan(isInUse: true, previous: nil, current: Self.snapshot(50),
                                   threshold: 3)
        #expect(plan.interval == PollPolicy.minInterval)
    }

    @Test func jitterStaysWithinTenPercent() {
        for _ in 0..<200 {
            let jittered = PollPolicy.jitter(300)
            #expect(jittered >= 270 && jittered <= 330)
        }
    }
}
