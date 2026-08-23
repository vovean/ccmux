import SwiftUI

struct SessionsPage: View {
    @ObservedObject var engine: Engine
    @ObservedObject var nav: NavigationState

    private var groups: [SessionGroup] {
        SessionGrouping.groups(accounts: engine.accounts,
                               sessions: engine.sessions,
                               unmanaged: engine.unmanagedSessions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if engine.sessions.isEmpty {
                    EmptyHint(title: "No managed sessions",
                              detail: "Start one with cc-opus or cc-fable in a terminal.")
                }
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
            .padding(14)
        }
        .onChange(of: Set(groups.map(\.id))) { _, ids in nav.retainOnly(ids) }
    }

    @ViewBuilder
    private func groupSection(_ group: SessionGroup) -> some View {
        let collapsed = nav.isCollapsed(group.id)
        VStack(alignment: .leading, spacing: 8) {
            groupHeader(group, collapsed: collapsed)
            if !collapsed {
                if group.isUnmanaged {
                    Text("Started outside ccmux, so each uses whichever account "
                         + "Claude Code is logged into.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    // Once per group: every session in it draws on the same quota.
                    ForEach(engine.usage[group.id]?.windows ?? []) { window in
                        UsageBar(window: window,
                                 threshold: engine.settings.warnThresholdPercent)
                    }
                }
                ForEach(group.sessions) { session in
                    sessionCard(session)
                }
                ForEach(group.unmanaged) { info in
                    unmanagedCard(info)
                }
            }
        }
    }

    private func groupHeader(_ group: SessionGroup, collapsed: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { nav.toggle(group.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title).font(.subheadline.weight(.semibold))
                if let subtitle = group.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
                StatusPill(text: "\(group.count)",
                           tint: group.isUnmanaged ? .secondary : .accentColor)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.count) sessions")
        .accessibilityHint(collapsed ? "Expand" : "Collapse")
    }

    private func unmanagedCard(_ info: ClaudeSessionInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.name ?? "claude").font(.subheadline)
                    if let status = info.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    Spacer()
                    Text("pid \(info.pid)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(Format.shortenHome(info.cwd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionCard(_ session: SessionRecord) -> some View {
        let info = engine.claudeSession(forPID: session.pid)
        let blocked = engine.blocks[session.id]
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if blocked != nil { RedDot() }
                    Text(info?.name ?? Format.shortenHome(session.cwd)).font(.headline)
                    if let status = info?.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    StatusPill(text: session.policyName, tint: .purple)
                    Spacer()
                    Menu {
                        Toggle("Auto-switch when exhausted", isOn: Binding(
                            get: {
                                session.autoSwitchEnabled(
                                    default: engine.settings.autoSwitch != .off)
                            },
                            set: { engine.setAutoSwitch($0, for: session.id) }))
                        Divider()
                        Button("Forget this session") { engine.endSession(session.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text(Format.shortenHome(session.cwd)).font(.caption).foregroundStyle(.secondary)

                if let blocked {
                    Text(blockedMessage(blocked))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    Text("Account").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { session.accountID },
                        set: { engine.assign(sessionID: session.id, to: $0) })) {
                        ForEach(engine.accounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer()
                    Text("pid \(session.pid) · port \(session.port)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func blockedMessage(_ blocked: BlockLedger.Entry) -> String {
        let account = engine.accounts.first { $0.id == blocked.accountID }?.displayName
            ?? "Its account"
        switch blocked.reason {
        case .pinned:
            return "\(account) is out of headroom and auto-switch is off for this "
                + "session, so it is stuck until you pick another account below."
        case .noneEligible:
            return "\(account) is out of headroom and no other account satisfies this "
                + "session's policy."
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "busy": return .green
        case "waiting": return .orange
        default: return .secondary
        }
    }

}
