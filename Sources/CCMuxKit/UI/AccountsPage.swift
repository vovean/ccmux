import SwiftUI

struct AccountsPage: View {
    @ObservedObject var engine: Engine
    @ObservedObject var nav: NavigationState
    @State private var showingAdd = false
    @State private var renaming: Account?
    @State private var renameText = ""
    @State private var confirmingRemoval: Account?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if engine.accounts.isEmpty {
                    EmptyHint(title: "No accounts yet",
                              detail: "Add a subscription, or import the login Claude Code "
                                  + "is already using on this Mac.")
                }
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

    private func accountCard(_ account: Account) -> some View {
        let sessionCount = engine.sessionCount(forAccount: account.id)
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if account.health == .needsRelogin { RedDot() }
                    Text(account.displayName).font(.headline)
                    if let plan = account.subscriptionType {
                        StatusPill(text: plan, tint: .secondary)
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
                        .disabled(engine.loginInProgress)
                    }
                }

                let windows = engine.usage[account.id]?.windows ?? []
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

    private func accountMenu(_ account: Account) -> some View {
        Menu {
            Button("Rename…") {
                renameText = account.label
                renaming = account
            }
            Button("Sign in again…") { engine.relogin(accountID: account.id) }
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
