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
    /// Headroom on the tightest window the policy cares about, or nil when the
    /// account is not eligible at all.
    public static func headroom(for account: Account, usage: UsageSnapshot?,
                                policy: Policy) -> AccountRanking? {
        guard account.health != .needsRelogin else { return nil }

        // An account we have never measured must not outrank every measured one just
        // for being unknown, so it starts from a neutral value: a healthy account with
        // real headroom wins, and an unknown one still beats a nearly-spent account.
        guard let usage, !usage.windows.isEmpty else {
            guard unknownHeadroom >= policy.minHeadroom else { return nil }
            return AccountRanking(accountID: account.id, headroom: unknownHeadroom,
                                  bindingWindow: nil)
        }

        var tightest = 100.0
        var binding: String?
        for kind in policy.requiredWindows {
            // No window of this kind means the account is not gated on it. A plan with
            // no per-model weekly cap reports no scoped window at all, and that is
            // unconstrained, not exhausted.
            for window in usage.windows(kind: kind, model: policy.scopedModel)
            where window.headroom < tightest {
                tightest = window.headroom
                binding = window.label
            }
        }
        guard tightest >= policy.minHeadroom else { return nil }
        return AccountRanking(accountID: account.id, headroom: tightest, bindingWindow: binding)
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
                            policy: Policy, excluding excluded: Set<String> = [])
        -> [AccountRanking] {
        accounts
            .filter { !excluded.contains($0.id) }
            .compactMap { account -> (AccountRanking, Int, String)? in
                guard let ranking = headroom(for: account, usage: usage[account.id],
                                             policy: policy) else { return nil }
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
                            policy: Policy, excluding excluded: Set<String> = [])
        -> AccountRanking? {
        rank(accounts: accounts, usage: usage, policy: policy, excluding: excluded).first
    }
}
