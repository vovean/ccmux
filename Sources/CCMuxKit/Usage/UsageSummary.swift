import CCMuxCore
import Foundation

/// One window kind, pooled across the accounts that could actually serve it.
struct SummaryRow: Identifiable, Equatable {
    var kind: UsageWindow.Kind
    var modelName: String?
    var label: String
    /// The mean across contributors. Only percentages come back from the API — no
    /// absolute quota — so the honest pooling is to treat each account as one equal unit
    /// of capacity. Two accounts at 40% and 60% read as one account's worth used.
    var percent: Double
    /// The soonest reset among the contributors, and no more than that. It is not when
    /// this pooled figure recovers — one account resetting lifts the mean by a quarter,
    /// not to zero — so the UI has to say "nearest" rather than "resets".
    var nearestReset: Date?
    /// Which account that reset belongs to, so the countdown can be attributed.
    var nearestResetAccount: String?
    var accountCount: Int
    var withHeadroomCount: Int

    var id: String { "\(kind.rawValue)/\(modelName ?? label)" }

    /// A synthetic window, so the summary draws through the same bar and the same
    /// threshold colouring as every per-account row.
    var window: UsageWindow {
        UsageWindow(kind: kind, label: label, percent: percent, resetsAt: nil,
                    modelName: modelName)
    }
}

struct UsageSummary: Equatable {
    var rows: [SummaryRow]
    /// Accounts that actually produced a window to pool — not merely eligible ones.
    ///
    /// The header counts these. Counting eligible accounts instead let a pool of one be
    /// presented as a fleet: two accounts with only one polled rendered that account's own
    /// bar under "Across 2 subscriptions", which reads as everything being exhausted when
    /// one thing is.
    var contributorCount: Int
    /// Eligible accounts with no usage yet, so a partial picture can admit it is partial.
    var unpolledCount: Int
    /// Of the contributors, how many have nothing left in a window every policy requires.
    var exhaustedCount: Int
    /// Any pooled window whose own reset has already passed. Its percent is then a figure
    /// from before that reset, and saying an account is out on the strength of it is
    /// exactly backwards.
    var hasStaleFigures: Bool
    /// The oldest reading in the pool, so figures from before a sleep are not read as live.
    var oldestReading: Date?

    var usableCount: Int { contributorCount - exhaustedCount }
}

enum UsageSummaries {
    /// Pools the windows of every account ccmux could actually choose.
    ///
    /// Deliberately narrower than "every subscription": an account held out of rotation or
    /// waiting on a sign-in has headroom that cannot be spent, and counting it inflates
    /// the one number this section exists to give. API keys are left out entirely — their
    /// windows are per-minute ceilings that refill continuously, so pooling them with
    /// quota that takes a week to come back would be meaningless.
    static func build(accounts: [Account], usage: [String: UsageSnapshot],
                      now: Date = Date()) -> UsageSummary {
        let eligible = accounts.filter {
            $0.isAutoAssignable && $0.health != .needsRelogin
        }

        var grouped: [String: [(window: UsageWindow, account: Account)]] = [:]
        var contributors: Set<String> = []
        var oldestReading: Date?
        var hasStaleFigures = false
        for account in eligible {
            guard let snapshot = usage[account.id] else { continue }
            var contributed = false
            for window in snapshot.windows where isPoolable(window) {
                grouped[window.id, default: []].append((window, account))
                contributed = true
                if let reset = window.resetsAt, reset <= now { hasStaleFigures = true }
            }
            guard contributed else { continue }
            contributors.insert(account.id)
            oldestReading = min(oldestReading ?? snapshot.fetchedAt, snapshot.fetchedAt)
        }

        let rows = grouped.values.map { entries -> SummaryRow in
            let windows = entries.map(\.window)
            let total = windows.reduce(0) { $0 + $1.percent }
            // A reset already in the past is not a nearest reset — it is a snapshot that
            // has not caught up. Dropping it gives the next one that will actually happen.
            let soonest = entries
                .compactMap { entry in entry.window.resetsAt.map { ($0, entry.account) } }
                .filter { $0.0 > now }
                .min { $0.0 < $1.0 }
            let first = windows[0]
            return SummaryRow(
                kind: first.kind,
                modelName: first.modelName,
                label: first.label,
                percent: total / Double(windows.count),
                nearestReset: soonest?.0,
                nearestResetAccount: soonest?.1.displayName,
                accountCount: windows.count,
                withHeadroomCount: windows.filter { $0.headroom > 0 }.count)
        }

        return UsageSummary(
            rows: rows.sorted(by: ordered),
            contributorCount: contributors.count,
            unpolledCount: eligible.count - contributors.count,
            // Only over accounts that reported something. An account with no snapshot is
            // unknown, not healthy, and counting it as healthy turned "one of two is
            // exhausted" into "all two can take a new session".
            exhaustedCount: eligible.filter {
                contributors.contains($0.id) && isExhausted($0, usage: usage[$0.id])
            }.count,
            hasStaleFigures: hasStaleFigures,
            oldestReading: oldestReading)
    }

    /// A per-minute ceiling refills continuously and says nothing about how much of a
    /// week is left; a budget is money rather than a server limit. Neither belongs in a
    /// pool of quota.
    private static func isPoolable(_ window: UsageWindow) -> Bool {
        !window.isPerMinute && window.kind != .budget
    }

    /// Nothing left in a window that every launch policy requires, so this account cannot
    /// take a session at all. Launch floors are deliberately not applied — they are a
    /// choice about where to *start* work, and this is a picture of what exists.
    private static func isExhausted(_ account: Account, usage: UsageSnapshot?) -> Bool {
        let windows = usage?.windows ?? []
        return windows.contains {
            ($0.kind == .session || $0.kind == .weeklyAll) && $0.headroom <= 0
        }
    }

    /// The order they are read in: the window that bites soonest first, then the week,
    /// then the per-model weeks by name.
    private static func ordered(_ a: SummaryRow, _ b: SummaryRow) -> Bool {
        if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
        return (a.modelName ?? a.label).localizedCaseInsensitiveCompare(
            b.modelName ?? b.label) == .orderedAscending
    }

    private static func rank(_ kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .session: return 0
        case .weeklyAll: return 1
        case .weeklyScoped: return 2
        default: return 3
        }
    }
}
