import CCMuxCore
import Charts
import SwiftUI

/// What the fleet has spent, in tokens, over time.
///
/// Everything here is the server's arithmetic. Three Macs each keep a running total of
/// their own, and pooling those on one screen is how you end up showing a number nobody
/// can reproduce — so this Mac hands over minutes and draws whatever comes back.
struct StatsPage: View {
    @ObservedObject var engine: Engine
    @State private var filter = StatsFilter()
    @State private var hovered: Date?
    /// Held rather than computed in `body`. Hovering writes the selection binding on
    /// every pointer move, and each write would otherwise re-run the whole filter, totals
    /// and sort pass twice per frame.
    @State private var selection: StatsSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = engine.statsError, engine.stats != nil {
                    staleNote(error)
                }
                if let response = engine.stats, let selection {
                    totalsCard(selection)
                    chartCard(response, selection)
                    accountsCard(selection)
                } else {
                    EmptyHint(title: emptyState.title, detail: emptyState.detail)
                }
            }
            .padding(14)
        }
        .task {
            engine.setStatsVisible(true)
            await engine.refreshStats(force: true)
        }
        .onDisappear { engine.setStatsVisible(false) }
        .onChange(of: engine.stats) { _, _ in rebuild() }
        .onChange(of: filter) { _, _ in rebuild() }
    }

    private func rebuild() {
        selection = engine.stats.map { StatsSelection.apply(filter, to: $0) }
    }

    /// Without this a failed refresh leaves the last answer on screen with its own
    /// timestamp beside it, and an hour-old chart reads as current.
    private func staleNote(_ error: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Showing the last answer — \(error)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { engine.statsRange },
                                          set: { engine.setStatsRange($0) })) {
                ForEach(UsageRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer(minLength: 8)

            if let selection {
                accountFilter(selection)
                modelFilter(selection)
            }
            Button {
                Task { await engine.refreshStats(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    private func accountFilter(_ selection: StatsSelection) -> some View {
        filterMenu(
            all: "All accounts", one: "account",
            options: selection.allAccounts.map { ($0.id, $0.accountLabel) },
            chosen: $filter.accounts)
    }

    private func modelFilter(_ selection: StatsSelection) -> some View {
        filterMenu(
            all: "All models", one: "model",
            options: selection.allModels.map { ($0, StatsSelection.shortModel($0)) },
            chosen: $filter.models)
    }

    private func filterMenu(all: String, one: String, options: [(String, String)],
                            chosen: Binding<Set<String>>) -> some View {
        Menu {
            Button(all) { chosen.wrappedValue = [] }
            Divider()
            ForEach(options, id: \.0) { id, label in
                Toggle(label, isOn: Binding(
                    get: { chosen.wrappedValue.contains(id) },
                    set: { on in
                        if on { chosen.wrappedValue.insert(id) }
                        else { chosen.wrappedValue.remove(id) }
                    }))
            }
        } label: {
            Text(chosen.wrappedValue.isEmpty ? all
                 : "\(chosen.wrappedValue.count) \(one)\(chosen.wrappedValue.count == 1 ? "" : "s")")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options.isEmpty)
    }

    // MARK: - Totals

    private func totalsCard(_ selection: StatsSelection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Total usage").font(.headline)
                    if let fetched = engine.statsFetchedAt {
                        Text("· \(Format.clock(fetched))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !filter.isEmpty {
                        Button("Clear filters") { filter = StatsFilter() }
                            .controlSize(.small)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    figure("Tokens", Format.tokens(selection.totals.tokens))
                    figure("Requests", "\(selection.totals.requests)")
                    figure(costLabel(selection), Format.money(selection.totals.costUSD))
                }
                breakdown(selection.totals)
                if let caveat = caveat(selection) {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func breakdown(_ totals: UsageTotals) -> some View {
        HStack(spacing: 14) {
            ForEach(Self.parts(totals), id: \.0) { name, count in
                Text("\(name) \(Format.tokens(count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func parts(_ totals: UsageTotals) -> [(String, Int)] {
        [("in", totals.input), ("out", totals.output), ("cache read", totals.cacheRead),
         ("cache write", totals.cacheWrite5m + totals.cacheWrite1h)]
    }

    /// Only an API key is actually billed per token. A subscription's figure is what the
    /// same traffic would list at, which is worth showing and worth labelling.
    private func costLabel(_ selection: StatsSelection) -> String {
        let kinds = Set(selection.allAccounts.map(\.kind))
        if kinds == [.apiKey] { return "Billed" }
        return kinds.contains(.apiKey) ? "Cost" : "At list price"
    }

    private func caveat(_ selection: StatsSelection) -> String? {
        var lines: [String] = []
        if selection.allAccounts.contains(where: { $0.kind == .subscription }) {
            lines.append("A subscription pays in quota, not per token — its dollars are "
                + "what the same traffic would list at.")
        }
        if !selection.totals.unpricedModels.isEmpty {
            lines.append("No listed price for "
                + selection.totals.unpricedModels.joined(separator: ", ")
                + ", so the cost is a floor.")
        }
        if engine.stats?.truncated == true {
            lines.append("Some of this range was dropped to keep the server inside its "
                + "storage ceiling, so these totals are short.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    // MARK: - Chart

    private func chartCard(_ response: UsageStatsResponse,
                           _ selection: StatsSelection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Over time").font(.headline)
                    Spacer()
                    if selection.matchedCount > selection.drawn.count {
                        Text("showing the \(selection.drawn.count) busiest of "
                             + "\(selection.matchedCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if selection.drawn.isEmpty {
                    EmptyHint(title: "Nothing matches",
                              detail: "No session used these accounts or models in this "
                                  + "range.")
                } else {
                    chart(response, selection)
                        .frame(height: 260)
                    legend(selection)
                }
            }
        }
    }

    private func chart(_ response: UsageStatsResponse,
                       _ selection: StatsSelection) -> some View {
        let snapped = hovered.flatMap {
            UsageGrid.floor($0, seconds: response.bucketSeconds)
        }
        return Chart {
            ForEach(selection.drawn) { series in
                ForEach(series.points) { point in
                    LineMark(x: .value("Time", point.at),
                             y: .value("Tokens", point.tokens))
                        // Keyed on the id, not the label: two sessions can share a name,
                        // and grouping by what is written under the chart would silently
                        // draw them as one line.
                        .foregroundStyle(by: .value("Series", series.id))
                        .interpolationMethod(.monotone)
                }
            }
            if let snapped {
                RuleMark(x: .value("Time", snapped))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, alignment: .center, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(at: snapped, response, selection)
                    }
            }
        }
        .chartForegroundStyleScale(domain: selection.drawn.map(\.id),
                                   range: selection.drawn.indices.map(Self.colour(for:)))
        .chartLegend(.hidden)
        .chartXSelection(value: $hovered)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(Format.tokens(count)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel(format: engine.statsRange == .day
                               ? .dateTime.hour().minute() : .dateTime.month().day())
            }
        }
    }

    /// The hover readout. Capped, because twelve rows over a 260-point chart covers the
    /// thing it is explaining.
    private func readout(at slot: Date, _ response: UsageStatsResponse,
                         _ selection: StatsSelection) -> some View {
        let rows = selection.drawn.compactMap { series -> Row? in
            guard let point = series.points.first(where: { $0.at == slot }) else {
                return nil
            }
            return Row(id: series.id, label: selection.label(series), point: point)
        }
        .sorted { $0.point.tokens > $1.point.tokens }
        let cost = rows.reduce(0) { $0 + $1.point.costUSD }
        let tokens = rows.reduce(0) { $0 + $1.point.tokens }
        let unpriced = rows.contains { $0.point.unpriced }

        return VStack(alignment: .leading, spacing: 3) {
            Text(Format.clock(slot))
                .font(.caption.weight(.semibold))
            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 8) {
                    Text(row.label).lineLimit(1)
                    Spacer(minLength: 10)
                    Text(Format.tokens(row.point.tokens)).monospacedDigit()
                    Text(Format.money(row.point.costUSD))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            if rows.count > 6 {
                Text("+ \(rows.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack(spacing: 8) {
                Text(rows.isEmpty ? "Nothing here" : "Total").font(.caption2.weight(.semibold))
                Spacer(minLength: 10)
                if !rows.isEmpty {
                    Text(Format.tokens(tokens)).font(.caption2.monospacedDigit())
                    Text(unpriced ? Format.money(cost) + "+" : Format.money(cost))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(7)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    /// Identified by the line, not by what is written under it: two sessions started in
    /// one directory are named the same and would collide as a ForEach id.
    private struct Row: Identifiable {
        let id: String
        let label: String
        let point: UsagePoint
    }

    private func legend(_ selection: StatsSelection) -> some View {
        // Wrapping rather than a fixed column count: a line's name is a session name, and
        // those run from four characters to forty.
        FlowLayout(spacing: 10) {
            ForEach(Array(selection.drawn.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.colour(for: index))
                        .frame(width: 7, height: 7)
                    Text(selection.label(series))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The same index the chart's own scale is built from, so a dot here is the colour of
    /// the line it names.
    static func colour(for index: Int) -> Color {
        let entry = StatsSelection.palette[index % StatsSelection.palette.count]
        return Color(red: entry.red, green: entry.green, blue: entry.blue)
    }

    // MARK: - Accounts

    private func accountsCard(_ selection: StatsSelection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Per account").font(.headline)
                if selection.accounts.isEmpty {
                    Text("No account used tokens in this range.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selection.accounts) { account in
                        HStack(spacing: 8) {
                            Text(account.accountLabel).lineLimit(1)
                            StatusPill(text: account.kind == .apiKey ? "billed" : "quota",
                                       tint: account.kind == .apiKey ? .orange : .secondary)
                            Spacer(minLength: 10)
                            Text("\(account.totals.requests) req")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(Format.tokens(account.totals.tokens))
                                .font(.callout.monospacedDigit())
                            Text(Format.money(account.totals.costUSD))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 74, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty states

    /// One ladder rather than two: a title and a detail that disagree about which case
    /// they are describing is what two parallel ones drift into.
    private var emptyState: (title: String, detail: String) {
        if !engine.isConnectedToServer {
            return ("No account server",
                    "Usage is pooled by ccmuxd so every Mac sees the same numbers. "
                        + "Connect one in Settings.")
        }
        if engine.serverSupportsUsageSeries == false {
            return ("This server is too old",
                    "Upgrade ccmuxd to the build that collects usage.")
        }
        if let error = engine.statsError {
            return ("Could not read the stats", error)
        }
        return ("Nothing recorded yet",
                "ccmux counts from the moment it is installed, and hands a minute over "
                    + "once that minute has ended.")
    }
}

/// A left-to-right wrap. `LazyVGrid` cannot do it — every column would be as wide as the
/// longest session name in the legend.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Measured once per layout pass and handed to both halves. Asking each subview for
    /// its size is the expensive part, and without this it was asked three times.
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout [CGSize]) -> CGSize {
        let rows = arrange(cache, in: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout [CGSize]) {
        var y = bounds.minY
        for row in arrange(cache, in: bounds.width) {
            var x = bounds.minX
            for index in row.members {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += cache[index].width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var members: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ sizes: [CGSize], in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in sizes.indices {
            let size = sizes[index]
            let gap = row.members.isEmpty ? 0 : spacing
            if !row.members.isEmpty, row.width + gap + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.members.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.members.append(index)
        }
        if !row.members.isEmpty { rows.append(row) }
        return rows
    }
}
