import Foundation

public struct AccountRanking: Equatable {
    public var accountID: String
    public var headroom: Double
    public var bindingWindow: String?
}

/// Picks which account a session should run on.
///
/// A policy names the windows it cares about, which is what makes `cc-opus` and
/// `cc-fable` different: an account whose Fable weekly window is exhausted is still a
/// perfectly good Opus account, so the opus policy simply does not look at that
/// window.
public enum PolicyEngine {
    /// Headroom for ranking, or nil when the account is not eligible at all.
    ///
    /// `applyingLaunchFloors` gates on the policy's per-window minimums; failover passes
    /// false and only requires the windows to be non-zero.
    public static func headroom(for account: Account, usage: UsageSnapshot?,
                                policy: Policy,
                                applyingLaunchFloors: Bool = false) -> AccountRanking? {
        guard account.health != .needsRelogin else { return nil }

        // An account we have never measured must not outrank every measured one just for
        // being unknown, so it starts from a neutral value.
        guard let usage, !usage.windows.isEmpty else {
            return AccountRanking(accountID: account.id, headroom: unknownHeadroom,
                                  bindingWindow: nil)
        }

        var rankOn = 100.0
        var binding: String?
        var sawWeekly = false
        for kind in policy.requiredWindows {
            let floor = applyingLaunchFloors ? policy.floor(for: kind) : 0
            // No window of this kind means the account is not gated on it. A plan with no
            // per-model weekly cap reports no scoped window at all, and that is
            // unconstrained, not exhausted.
            for window in usage.windows(kind: kind, model: policy.scopedModel) {
                guard window.headroom > 0, window.headroom >= floor else { return nil }
                // Ranked on weekly headroom only: the 5-hour window refills all day, so
                // ranking on it would reshuffle the order every few hours without using
                // up any more of the subscription.
                guard kind == .weeklyAll || kind == .weeklyScoped else { continue }
                sawWeekly = true
                if window.headroom < rankOn {
                    rankOn = window.headroom
                    binding = window.label
                }
            }
        }
        if !sawWeekly {
            // A policy with no weekly window to rank on falls back to the tightest gate.
            for kind in policy.requiredWindows {
                for window in usage.windows(kind: kind, model: policy.scopedModel)
                where window.headroom < rankOn {
                    rankOn = window.headroom
                    binding = window.label
                }
            }
        }
        return AccountRanking(accountID: account.id, headroom: rankOn, bindingWindow: binding)
    }

    /// Ranking value for an account with no usage data at all.
    public static let unknownHeadroom: Double = 50

    /// Requires headroom on every window an account reports, including all per-model
    /// ones (`scopedModel: nil` matches them all). Used when a session has to move off
    /// an exhausted account and the window that ran out may not be one its launch policy
    /// cares about.
    public static let everyWindow = Policy(
        name: "every-window",
        requiredWindows: [.session, .weeklyAll, .weeklyScoped, .other])

    /// Eligible accounts, **least remaining first**.
    ///
    /// Drain one subscription before starting on the next, rather than spreading load
    /// evenly. Three half-used subscriptions at the end of the week is wasted quota;
    /// one spent and two fresh is not. Ranking is on the tightest window the policy
    /// gates on, and eligibility still requires headroom on *every* one of them — a
    /// Fable request will not take an account that only has general weekly left.
    public static func rank(accounts: [Account], usage: [String: UsageSnapshot],
                            policy: Policy, excluding excluded: Set<String> = [],
                            applyingLaunchFloors: Bool = false) -> [AccountRanking] {
        accounts
            .filter { !excluded.contains($0.id) }
            .compactMap { account -> (AccountRanking, Int, String)? in
                guard let ranking = headroom(for: account, usage: usage[account.id],
                                             policy: policy,
                                             applyingLaunchFloors: applyingLaunchFloors)
                else { return nil }
                return (ranking, account.priority, account.displayName)
            }
            .sorted { lhs, rhs in
                if lhs.0.headroom != rhs.0.headroom { return lhs.0.headroom < rhs.0.headroom }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2.localizedCaseInsensitiveCompare(rhs.2) == .orderedAscending
            }
            .map(\.0)
    }

    /// The account to use: the most-drained one that can still serve the policy.
    public static func pick(accounts: [Account], usage: [String: UsageSnapshot],
                            policy: Policy, excluding excluded: Set<String> = [],
                            applyingLaunchFloors: Bool = false) -> AccountRanking? {
        rank(accounts: accounts, usage: usage, policy: policy, excluding: excluded,
             applyingLaunchFloors: applyingLaunchFloors).first
    }
}
