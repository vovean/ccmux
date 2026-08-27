import CCMuxCore
import Foundation

/// Moving sessions that are already running to a different account, on demand.
///
/// Failover is reactive: it fires on a refusal, so a session pushed off an exhausted
/// account stays there long after the account recovers. This asks the launcher's own
/// question — "which account would this session start on right now" — of a session that
/// is already running. Nothing calls it on a timer; it exists for the Reassign menu.
public enum Rebalance {
    public enum Scope: Equatable {
        /// Every session that is not mid-turn.
        case idle
        /// Every session, mid-turn ones included.
        case all
    }

    /// Why a session was left where it is. Reported back so a manual reassign that
    /// moves nothing says which of these it was.
    public enum Skip: String, Equatable, Comparable {
        case pinned
        case busy
        case manualAccount
        case settled
        case noCandidate

        var phrase: String {
            switch self {
            case .pinned: return "auto-switch off"
            case .busy: return "mid-turn"
            case .manualAccount: return "on a hand-picked account"
            case .settled: return "already where it would launch"
            case .noCandidate: return "nowhere better to go"
            }
        }

        public static func < (lhs: Skip, rhs: Skip) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Move: Equatable {
        public var sessionID: String
        public var from: String
        public var to: String
    }

    public struct Plan: Equatable {
        public var moves: [Move] = []
        public var skipped: [String: Skip] = [:]
    }

    enum Decision: Equatable {
        case move(String)
        case skip(Skip)
    }

    public static func plan(sessions: [SessionRecord], accounts: [Account],
                            usage: [String: UsageSnapshot], settings: Settings,
                            live: [Int32: ClaudeSessionInfo], scope: Scope) -> Plan {
        let assignable = accounts.filter(\.isAutoAssignable)
        var plan = Plan()
        for record in sessions {
            switch decide(record, assignable: assignable,
                          current: accounts.first { $0.id == record.accountID },
                          usage: usage, settings: settings,
                          status: live[record.pid]?.status, scope: scope) {
            case .move(let to):
                plan.moves.append(Move(sessionID: record.id, from: record.accountID, to: to))
            case .skip(let reason):
                plan.skipped[record.id] = reason
            }
        }
        return plan
    }

    static func decide(_ record: SessionRecord, assignable: [Account], current: Account?,
                       usage: [String: UsageSnapshot], settings: Settings,
                       status: String?, scope: Scope) -> Decision {
        // The global auto-switch mode governs what ccmux does on its own, and a button
        // press is not that — only this session's own opt-out stops it.
        if record.autoSwitchOverride == false { return .skip(.pinned) }

        // An API key, or an account taken out of rotation: ccmux would never pick either
        // by itself, so a session on one is there because someone put it there.
        guard let current, current.isAutoAssignable else { return .skip(.manualAccount) }

        guard let policy = settings.policy(named: record.policyName) else {
            return .skip(.noCandidate)
        }

        // Moving mid-turn drops the prompt cache mid-answer. The exception is a session
        // its account can no longer serve, which has no turn to protect and is the case
        // that leaves a session parked for hours. Judged against the windows this
        // session's own policy gates on: a spent Fable week strands a `cc-fable` session
        // even though the account still answers everything else.
        let stranded = PolicyEngine.headroom(for: current, usage: usage[current.id],
                                             policy: policy) == nil
        if scope != .all, status == "busy", !stranded { return .skip(.busy) }

        guard let pick = PolicyEngine.pick(accounts: assignable, usage: usage,
                                           policy: policy, applyingLaunchFloors: true)
        else { return .skip(.noCandidate) }
        guard pick.accountID != current.id else { return .skip(.settled) }
        return .move(pick.accountID)
    }

    public static func report(moved: Int, failed: Int, skipped: [String: Skip]) -> String {
        var parts = [moved == 1 ? "Moved 1 session." : "Moved \(moved) sessions."]
        if failed > 0 {
            parts.append(failed == 1 ? "1 could not be moved."
                                     : "\(failed) could not be moved.")
        }
        let tally = Dictionary(grouping: skipped.values, by: { $0 })
            .sorted { $0.key < $1.key }
            .map { "\($0.value.count) \($0.key.phrase)" }
        if !tally.isEmpty {
            parts.append("Left alone: " + tally.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}
