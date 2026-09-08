import CCMuxCore
import Foundation

/// What the Stats page is showing, worked out from the server's answer and the two
/// filters. Kept out of the view so the rules are testable without rendering one.
public struct StatsFilter: Equatable, Sendable {
    /// Empty means every account, which is not the same as none — a filter that has to be
    /// fully populated to mean "all" goes wrong the moment a new account appears.
    public var accounts: Set<String> = []
    public var models: Set<String> = []

    public init(accounts: Set<String> = [], models: Set<String> = []) {
        self.accounts = accounts
        self.models = models
    }

    public var isEmpty: Bool { accounts.isEmpty && models.isEmpty }

    public func matches(_ series: UsageSeries) -> Bool {
        if !accounts.isEmpty,
           !accounts.contains(StatsSelection.accountKey(series)) { return false }
        if !models.isEmpty, !models.contains(series.model) { return false }
        return true
    }
}

public struct StatsSelection: Equatable, Sendable {
    /// The lines actually drawn, biggest first.
    public var drawn: [UsageSeries]
    /// Every line the filters kept, drawn or not. Their tokens are all in `totals` — the
    /// chart is what is capped, not the arithmetic.
    public var matchedCount: Int
    public var totals: UsageTotals
    public var accounts: [UsageAccountTotals]
    /// Every model and account the answer contains, filter or no filter, so switching one
    /// off does not remove it from the menu that switches it back on.
    public var allModels: [String]
    public var allAccounts: [UsageAccountTotals]
    /// Set when the answer spans more than one Mac, which is what decides whether a line
    /// has to say where it ran.
    public var multipleMachines: Bool
    /// Lines whose session and model also appear under another account, and so have to
    /// say which one. ccmux moves a session between accounts, so this is ordinary.
    public var sharedNames: Set<String>

    /// About the limit of a legend anyone can read, and past it the lines overlap into a
    /// smear. Matches the palette below.
    public static let maxLines = 12

    public static func accountKey(_ series: UsageSeries) -> String {
        series.accountFingerprint ?? series.accountID
    }

    public static func apply(_ filter: StatsFilter,
                             to response: UsageStatsResponse) -> StatsSelection {
        let matched = response.series.filter(filter.matches)
        var models = Set<String>()
        for series in response.series { models.insert(series.model) }

        var totals = UsageTotals()
        var unpriced = Set<String>()
        var byAccount: [String: UsageTotals] = [:]
        var unpricedByAccount: [String: Set<String>] = [:]
        for series in matched {
            totals.add(series.totals)
            unpriced.formUnion(series.totals.unpricedModels)
            let key = accountKey(series)
            byAccount[key, default: UsageTotals()].add(series.totals)
            unpricedByAccount[key, default: []].formUnion(series.totals.unpricedModels)
        }
        totals.unpricedModels = unpriced.sorted()

        // Rebuilt from the matched lines rather than taken from the answer, so the table
        // and the chart cannot disagree once a model filter is on.
        let accounts = response.accounts.compactMap { account -> UsageAccountTotals? in
            let key = account.id
            guard var totals = byAccount[key] else { return nil }
            totals.unpricedModels = (unpricedByAccount[key] ?? []).sorted()
            var row = account
            row.totals = totals
            return row
        }

        var accountsByName: [String: Set<String>] = [:]
        for series in response.series {
            accountsByName[nameKey(series), default: []].insert(accountKey(series))
        }

        return StatsSelection(
            drawn: Array(matched.prefix(maxLines)),
            matchedCount: matched.count,
            totals: totals,
            accounts: accounts,
            allModels: models.sorted(),
            allAccounts: response.accounts,
            multipleMachines: Set(response.series.map(\.machineID)).count > 1,
            sharedNames: Set(accountsByName.filter { $0.value.count > 1 }.keys))
    }

    static func nameKey(_ series: UsageSeries) -> String {
        "\(series.machineID)\u{0}\(series.sessionID)\u{0}\(series.model)"
    }

    /// How a line is named. The machine only when there is more than one, and the account
    /// only when the same session and model ran on another as well — a fleet of one
    /// should not repeat its own name down the whole legend.
    public func label(_ series: UsageSeries) -> String {
        Self.label(series, machines: multipleMachines,
                   account: sharedNames.contains(Self.nameKey(series)))
    }

    public static func label(_ series: UsageSeries, machines: Bool,
                             account: Bool = false) -> String {
        let name = series.sessionName.isEmpty ? String(series.sessionID.prefix(8))
            : series.sessionName
        var parts = [name, shortModel(series.model)]
        if account { parts.append(series.accountLabel) }
        if machines { parts.append(series.machineLabel) }
        return parts.joined(separator: " · ")
    }

    /// "claude-fable-5-1" reads as "fable-5-1" in a legend, and the prefix is on every
    /// line so it distinguishes nothing.
    public static func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    /// Indexed by where a line sits in `drawn`, and declared as the chart's own scale
    /// rather than left to the default palette — the legend is drawn by hand and the two
    /// have to agree.
    public static let palette: [(red: Double, green: Double, blue: Double)] = [
        (0.20, 0.47, 0.96), (0.18, 0.68, 0.35), (0.95, 0.58, 0.11),
        (0.55, 0.36, 0.86), (0.90, 0.27, 0.27), (0.13, 0.68, 0.71),
        (0.35, 0.40, 0.85), (0.60, 0.45, 0.30), (0.20, 0.75, 0.85),
        (0.30, 0.80, 0.60), (0.92, 0.42, 0.65), (0.85, 0.72, 0.15),
    ]


}

public extension UsageTotals {
    mutating func add(_ other: UsageTotals) {
        requests += other.requests
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        costUSD += other.costUSD
    }
}
