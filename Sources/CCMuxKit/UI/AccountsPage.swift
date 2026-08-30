import CCMuxCore
import SwiftUI

struct AccountsPage: View {
    @ObservedObject var engine: Engine
    @ObservedObject var nav: NavigationState
    @State private var showingAdd = false
    @State private var renaming: Account?
    @State private var renameText = ""
    @State private var confirmingRemoval: Account?
    @State private var budgeting: Account?
    @State private var budgetText = ""
    @State private var budgetError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if engine.accounts.isEmpty {
                    EmptyHint(title: "No accounts yet",
                              detail: "Add a subscription, or import the login Claude Code "
                                  + "is already using on this Mac.")
                }
                summarySection
                ForEach(engine.accounts) { account in
                    accountCard(account)
                }
            }
            .padding(14)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    engine.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Fetch usage now")

                Button {
                    Task { await engine.importGlobalLogin() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import the login Claude Code is already using")

                Button {
                    showingAdd = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddAccountSheet(engine: engine)
        }
        .sheet(item: $renaming) { account in
            renameSheet(account)
        }
        .sheet(item: $budgeting) { account in
            budgetSheet(account)
        }
        .alert("Remove \(confirmingRemoval?.displayName ?? "")?",
               isPresented: Binding(get: { confirmingRemoval != nil },
                                    set: { if !$0 { confirmingRemoval = nil } })) {
            Button("Remove", role: .destructive) {
                if let account = confirmingRemoval { engine.removeAccount(account.id) }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text("Its stored credential is deleted and any session using it ends. "
                 + "The subscription itself is untouched.")
        }
    }

    /// The pooled picture across every account ccmux could pick.
    ///
    /// Hidden below two contributors: with one account this is that account's card said
    /// twice, and the word "nearest" would be describing a set of one.
    @ViewBuilder
    private var summarySection: some View {
        let summary = UsageSummaries.build(accounts: engine.accounts, usage: engine.usage)
        // Gated on accounts that actually reported, not on eligible ones. A pool of one is
        // that account's own card repeated under a heading that claims to speak for
        // several — which reads as the whole fleet being exhausted when one thing is.
        if summary.contributorCount >= 2 && !summary.rows.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Across \(summary.contributorCount) subscriptions")
                            .font(.headline)
                        Spacer()
                        if let oldest = summary.oldestReading, oldest > .distantPast {
                            Text("oldest reading \(Format.clock(oldest))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Figures are only as current as the account that "
                                      + "was polled longest ago.")
                        }
                    }

                    ForEach(summary.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            UsageBar(window: row.window,
                                     threshold: engine.settings.warnThresholdPercent,
                                     reset: resetLabel(row))
                            if let note = rowNote(row, of: summary) {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Text(capacityLine(summary))
                        .font(.caption)
                        .foregroundStyle(summary.exhaustedCount > 0 ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Averaging percentages is only meaningful because the API gives no
                    // absolute quota; saying so stops the number being read as one pot.
                    Text("Each figure is the average across those accounts, so 50% means "
                         + "about half your total capacity is gone.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Never the bare countdown: this reset belongs to whichever account happens to be
    /// first, and one of several resetting lifts the average by a fraction rather than
    /// clearing the bar.
    private func resetLabel(_ row: SummaryRow) -> (note: String, help: String)? {
        guard let reset = row.nearestReset else { return nil }
        let owner = row.nearestResetAccount ?? "an account"
        let others = row.accountCount > 1
            ? " The others reset later, so this bar does not empty then." : ""
        return ("nearest reset in \(Format.countdown(to: reset))",
                "Soonest of \(row.accountCount): \(owner) at \(Format.clock(reset))."
                    + others)
    }

    /// Says how many accounts a row actually speaks for, whenever that is not all of them
    /// or not all of them have room. Without it a per-model week that one account has
    /// exhausted looks identical to the whole pool being out.
    private func rowNote(_ row: SummaryRow, of summary: UsageSummary) -> String? {
        var parts: [String] = []
        if row.accountCount < summary.contributorCount {
            parts.append("\(row.accountCount) of \(summary.contributorCount) accounts "
                         + "report this window")
        }
        let out = row.accountCount - row.withHeadroomCount
        if out > 0 {
            parts.append(out == row.accountCount
                         ? "all of them are out of it"
                         : "\(out) of them \(out == 1 ? "is" : "are") out of it")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func capacityLine(_ summary: UsageSummary) -> String {
        // A window whose reset has passed still carries its pre-reset percent until the
        // next poll lands. Asserting anyone is out on the strength of that is precisely
        // backwards — after a sleep it would read "none can take a new session" at the
        // moment everything became free.
        if summary.hasStaleFigures {
            return "Some windows have already reset — these figures are from before that "
                + "and update on the next poll."
        }
        let usable = summary.usableCount
        let noun = usable == 1 ? "account" : "accounts"
        let trailer = summary.unpolledCount > 0
            ? " \(summary.unpolledCount) not polled yet." : ""
        if summary.exhaustedCount == 0 {
            return "All \(summary.contributorCount) can take a new session." + trailer
        }
        if usable == 0 {
            return "None can take a new session — every account is out until its reset."
                + trailer
        }
        return "\(usable) \(noun) can take a new session · "
            + "\(summary.exhaustedCount) out until reset." + trailer
    }

    private func accountCard(_ account: Account) -> some View {
        let sessionCount = engine.sessionCount(forAccount: account.id)
        let elsewhere = engine.foreignSessionCount(forAccount: account.id)
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if account.health == .needsRelogin { RedDot() }
                    Text(account.displayName).font(.headline)
                    if account.kind == .apiKey {
                        StatusPill(text: "API key", tint: .orange)
                    } else if let plan = account.subscriptionType {
                        StatusPill(text: plan, tint: .secondary)
                    }
                    if !account.inRotation {
                        StatusPill(text: "out of rotation", tint: .secondary)
                    }
                    if sessionCount > 0 {
                        Button {
                            nav.showSessions(forAccount: account.id)
                        } label: {
                            StatusPill(text: "\(sessionCount) session"
                                       + (sessionCount == 1 ? "" : "s"), tint: .accentColor)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Show these sessions")
                    }
                    if elsewhere > 0 {
                        Button {
                            nav.showSessions(forAccount: account.id)
                        } label: {
                            StatusPill(text: "+\(elsewhere) elsewhere", tint: .secondary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Running on "
                              + engine.foreignMachineNames(forAccount: account.id)
                                  .joined(separator: ", "))
                    }
                    Spacer()
                    accountMenu(account)
                }

                if let email = account.email, email != account.displayName {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }

                if account.health == .needsRelogin {
                    HStack(spacing: 8) {
                        Text(account.healthDetail ?? "Sign-in expired.")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Sign in again") { engine.relogin(accountID: account.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    }
                }

                if account.kind == .apiKey { spendLine(account) }

                let windows = bars(for: account)
                if windows.isEmpty {
                    Text(engine.usage[account.id]?.lastError ?? "No usage data yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(windows) { window in
                        UsageBar(window: window,
                                 threshold: engine.settings.warnThresholdPercent)
                    }
                }

                HStack(spacing: 10) {
                    if let profile = engine.chromeProfile(for: account) {
                        Label(profile.label, systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if account.chromeProfileDirectory != nil {
                        Label("Chrome profile \(account.chromeProfileDirectory!) (not found)",
                              systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let snapshot = engine.usage[account.id], snapshot.fetchedAt > .distantPast {
                        Text("updated \(Format.clock(snapshot.fetchedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Accepts what people actually type. Returns nil for anything unparseable so a
    /// typo is reported rather than silently clearing the budget — Clear is a button.
    static func parseBudget(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    /// Server limits first, then the budget — money reads as one more ceiling.
    private func bars(for account: Account) -> [UsageWindow] {
        var windows = engine.usage[account.id]?.windows ?? []
        if let budget = Engine.budgetWindow(for: account) { windows.append(budget) }
        return windows
    }

    /// Live spend is what the sessions on screen have run up; the lifetime figure keeps
    /// counting after they end, so money never appears to vanish.
    private func spendLine(_ account: Account) -> some View {
        let live = engine.liveSpend(forAccount: account.id)
        let month = account.spendThisMonth?.amount() ?? 0
        return HStack(spacing: 10) {
            Label(Format.money(live), systemImage: "bolt.fill")
                .font(.caption.monospacedDigit())
                .foregroundStyle(live > 0 ? .primary : .secondary)
                .help("Spent by sessions running now")
            Text("· \(Format.money(month)) this month")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("· \(Format.money(account.spendLifetimeUSD)) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if !engine.unpricedModels.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Incomplete: no listed price for "
                          + engine.unpricedModels.sorted().joined(separator: ", "))
            }
            Spacer()
        }
    }

    private func budgetSheet(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly budget for \(account.displayName)").font(.headline)
            HStack {
                Text("$")
                TextField("none", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            if let budgetError {
                Text(budgetError).font(.caption).foregroundStyle(.red)
            }
            Text("Warns at \(Int(engine.settings.budgetWarnPercent))% and again when "
                 + "exceeded. Nothing is ever blocked — a hard stop would strand whatever "
                 + "session is on the key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") {
                    engine.setMonthlyBudget(nil, for: account.id)
                    budgeting = nil
                }
                .help("Remove the budget entirely")
                Spacer()
                Button("Cancel") { budgeting = nil }
                Button("Save") {
                    if let amount = Self.parseBudget(budgetText) {
                        engine.setMonthlyBudget(amount, for: account.id)
                        budgeting = nil
                    } else {
                        budgetError = "Enter an amount like 50 or 1,000."
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func accountMenu(_ account: Account) -> some View {
        Menu {
            Button("Rename…") {
                renameText = account.label
                renaming = account
            }
            if account.kind == .subscription {
                Button("Sign in again…") { engine.relogin(accountID: account.id) }
            }
            Toggle("In rotation", isOn: Binding(
                get: { account.inRotation },
                set: { engine.setInRotation($0, for: account.id) }))
            if account.kind == .apiKey {
                Button("Set monthly budget…") {
                    budgetText = account.monthlyBudgetUSD.map { String(format: "%.0f", $0) } ?? ""
                    budgeting = account
                }
            }
            Divider()
            Button("Move up") { engine.movePriority(account.id, by: -1) }
            Button("Move down") { engine.movePriority(account.id, by: 1) }
            Divider()
            Button("Remove…", role: .destructive) { confirmingRemoval = account }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func renameSheet(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename account").font(.headline)
            TextField("Label", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Save") {
                    engine.setLabel(renameText, for: account.id)
                    renaming = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

}
