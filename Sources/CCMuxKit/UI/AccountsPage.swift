import CCMuxCore
import SwiftUI

struct AccountsPage: View {
    @ObservedObject var engine: Engine
    @ObservedObject var nav: NavigationState
    @State private var showingAdd = false
    @State private var renaming: Account?
    /// The text in whichever name sheet is open; only one is at a time.
    @State private var nameText = ""
    @State private var confirmingRemoval: Account?
    @State private var budgeting: Account?
    @State private var budgetText = ""
    @State private var budgetError: String?
    /// The account a new group is being created for, from its Group menu.
    @State private var groupingAccount: Account?
    @State private var renamingGroup: SubscriptionGroup?
    @State private var deletingGroup: SubscriptionGroup?

    /// An account in several groups is listed under each. One whose groups are not loaded
    /// yet is listed with the ungrouped ones rather than vanishing from the page.
    private var sections: (ungrouped: [Account], byGroup: [String: [Account]]) {
        var ungrouped: [Account] = []
        var byGroup: [String: [Account]] = [:]
        for account in engine.accounts {
            let listed = loadedGroups(of: account)
            if listed.isEmpty { ungrouped.append(account) }
            for group in listed { byGroup[group, default: []].append(account) }
        }
        return (ungrouped, byGroup)
    }

    private func loadedGroups(of account: Account) -> [String] {
        account.groupIDs.filter { id in engine.groups.contains { $0.id == id } }
    }

    var body: some View {
        dialogs(sheets(content))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if engine.accounts.isEmpty {
                    EmptyHint(title: "No accounts yet",
                              detail: "Add a subscription, or import the login Claude Code "
                                  + "is already using on this Mac.")
                }
                summarySection
                let sections = sections
                ForEach(sections.ungrouped) { account in
                    accountCard(account)
                }
                ForEach(engine.groups) { group in
                    groupSection(group, accounts: sections.byGroup[group.id] ?? [])
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
    }

    private func sheets<V: View>(_ view: V) -> some View {
        view
        .sheet(isPresented: $showingAdd) {
            AddAccountSheet(engine: engine)
        }
        .sheet(item: $renaming) { account in
            nameSheet("Rename account", field: "Label", confirm: "Save", requiresName: false,
                      dismiss: { renaming = nil }) { label in
                engine.setLabel(label, for: account.id)
            }
        }
        .sheet(item: $budgeting) { account in
            budgetSheet(account)
        }
        .sheet(item: $groupingAccount) { account in
            nameSheet("New group", note: "\(account.displayName) is added to it.",
                      confirm: "Create", dismiss: { groupingAccount = nil }) { name in
                Task { await engine.createGroup(named: name, adding: account.id) }
            }
        }
        .sheet(item: $renamingGroup) { group in
            nameSheet("Rename group", confirm: "Save",
                      dismiss: { renamingGroup = nil }) { name in
                Task { await engine.renameGroup(group.id, to: name) }
            }
        }
    }

    private func dialogs<V: View>(_ view: V) -> some View {
        view
        .alert("Remove \(confirmingRemoval?.displayName ?? "")?",
               isPresented: Binding(get: { confirmingRemoval != nil },
                                    set: { if !$0 { confirmingRemoval = nil } })) {
            if engine.isConnectedToServer {
                Button("Remove from this Mac") { remove(everywhere: false) }
                Button("Remove everywhere", role: .destructive) { remove(everywhere: true) }
            } else {
                Button("Remove", role: .destructive) { remove(everywhere: false) }
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text(removalMessage)
        }
        .alert("Delete the group \(deletingGroup?.name ?? "")?",
               isPresented: Binding(get: { deletingGroup != nil },
                                    set: { if !$0 { deletingGroup = nil } })) {
            Button("Delete group", role: .destructive) {
                if let group = deletingGroup { Task { await engine.deleteGroup(group.id) } }
                deletingGroup = nil
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text(Self.groupDeletionMessage)
        }
    }

    private var removalMessage: String {
        engine.isConnectedToServer ? Self.sharedRemovalMessage : Self.localRemovalMessage
    }

    private static let sharedRemovalMessage = "From this Mac only, it stays on the account "
        + "server and other machines keep using it; sync will not bring it back here. "
        + "Everywhere deletes it from the server, and every machine drops it. Sessions "
        + "using it here end either way."
    private static let localRemovalMessage = "Its stored credential is deleted and any "
        + "session using it ends. The subscription itself is untouched."
    private static let groupDeletionMessage = "Its accounts stay, in their other groups or "
        + "ungrouped, on every machine. A machine limited to this group has nothing to "
        + "choose from until it is given another."

    private func remove(everywhere: Bool) {
        if let account = confirmingRemoval {
            Task { await engine.removeAccount(account.id, everywhere: everywhere) }
        }
        confirmingRemoval = nil
    }

    // MARK: - Groups

    @ViewBuilder
    private func groupSection(_ group: SubscriptionGroup, accounts: [Account]) -> some View {
        let collapsed = engine.settings.collapsedAccountGroups.contains(group.id)
        VStack(alignment: .leading, spacing: 10) {
            groupHeader(group, accounts: accounts, collapsed: collapsed)
            if !collapsed {
                ForEach(accounts) { account in
                    accountCard(account)
                }
                if accounts.isEmpty {
                    Text("No accounts yet. Add one from its ••• menu, under Groups.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(.top, 6)
    }

    private func groupHeader(_ group: SubscriptionGroup, accounts: [Account],
                             collapsed: Bool) -> some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    engine.setGroupCollapsed(group.id, !collapsed)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(group.name).font(.subheadline.weight(.semibold))
                    StatusPill(text: "\(accounts.count)", tint: .secondary)
                    if engine.settings.restrictedGroupID == group.id {
                        StatusPill(text: "this Mac", tint: .accentColor)
                            .help("This Mac chooses accounts only from this group")
                    }
                    Text(groupCapacity(group.id))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(accounts.count) accounts")
            .accessibilityHint(collapsed ? "Shows this group's accounts"
                                         : "Hides this group's accounts")
            Spacer()
            Menu {
                Button("Rename group…") {
                    nameText = group.name
                    renamingGroup = group
                }
                Button("Delete group…", role: .destructive) { deletingGroup = group }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func groupCapacity(_ groupID: String) -> String {
        let summary = UsageSummaries.build(accounts: engine.accounts, usage: engine.usage,
                                           group: groupID)
        guard summary.contributorCount > 0 else { return "" }
        return "\(summary.usableCount) of \(summary.contributorCount) can take a new session"
    }

    private func nameSheet(_ title: String, note: String? = nil, field: String = "Name",
                           confirm: String, requiresName: Bool = true,
                           dismiss: @escaping () -> Void,
                           onConfirm: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            TextField(field, text: $nameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button(confirm) {
                    onConfirm(nameText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(requiresName && nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    /// The pooled picture across every account ccmux could pick.
    ///
    /// Hidden below two contributors: with one account this is that account's card said
    /// twice, and the word "nearest" would be describing a set of one.
    private var summarySection: some View {
        // Ticks with the bars below it, and off one instant for the whole section: `build`
        // drops resets already past and the label counts down to the one it kept, so two
        // separate reads of the clock are how a row ends up counting down to a reset the
        // pooling had already discarded.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            summaryCard(now: context.date)
        }
    }

    @ViewBuilder
    private func summaryCard(now: Date) -> some View {
        let summary = UsageSummaries.build(accounts: engine.accounts, usage: engine.usage,
                                           group: engine.settings.restrictedGroupID, now: now)
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
                                     reset: resetLabel(row, now: now))
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
    private func resetLabel(_ row: SummaryRow, now: Date) -> (note: String, help: String)? {
        guard let reset = row.nearestReset else { return nil }
        let owner = row.nearestResetAccount ?? "an account"
        let others = row.accountCount > 1
            ? " The others reset later, so this bar does not empty then." : ""
        return ("nearest reset in \(Format.countdown(to: reset, from: now))",
                "Soonest of \(row.accountCount): \(owner) at "
                    + "\(Format.clock(reset, now: now))." + others)
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
                    if !account.groupIDs.isEmpty, loadedGroups(of: account).isEmpty {
                        StatusPill(text: "group not loaded", tint: .secondary)
                            .help("In a group this Mac has not loaded yet, so it is left "
                                  + "to the machines limited to that group")
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
                nameText = account.label
                renaming = account
            }
            if account.kind == .subscription {
                Button("Sign in again…") { engine.relogin(accountID: account.id) }
            }
            Toggle("In rotation", isOn: Binding(
                get: { account.inRotation },
                set: { engine.setInRotation($0, for: account.id) }))
            groupMenu(account)
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

    @ViewBuilder
    private func groupMenu(_ account: Account) -> some View {
        if engine.serverSupportsGroups {
            Menu("Groups") {
                ForEach(engine.groups) { group in
                    Toggle(group.name, isOn: Binding(
                        get: { account.groupIDs.contains(group.id) },
                        set: { on in
                            Task {
                                await engine.setMembership(group.id, member: on,
                                                           for: account.id)
                            }
                        }))
                }
                if !engine.groups.isEmpty { Divider() }
                Button("New group…") {
                    nameText = ""
                    groupingAccount = account
                }
            }
            // An older ccmuxd keeps one group per account and has no route to add a second.
            .disabled(!engine.sharesSettings(account.id) || !engine.serverSupportsGroupSets)
        }
    }

}
