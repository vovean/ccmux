import SwiftUI

struct SessionsPage: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if engine.sessions.isEmpty {
                    EmptyHint(title: "No managed sessions",
                              detail: "Start one with cc-opus or cc-fable in a terminal.")
                }
                ForEach(engine.sessions) { session in
                    sessionCard(session)
                }

                if !engine.unmanagedSessions.isEmpty {
                    Text("Not managed by ccmux")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(engine.unmanagedSessions) { info in
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
                                Text(shortPath(info.cwd))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Started outside ccmux, so it uses whichever account "
                                     + "Claude Code is logged into.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func sessionCard(_ session: SessionRecord) -> some View {
        let info = engine.claudeSession(forPID: session.pid)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(info?.name ?? shortPath(session.cwd)).font(.headline)
                    if let status = info?.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    StatusPill(text: session.policyName, tint: .purple)
                    Spacer()
                    Menu {
                        Toggle("Auto-switch when exhausted", isOn: Binding(
                            get: { session.autoSwitch },
                            set: { engine.setAutoSwitch($0, for: session.id) }))
                        Divider()
                        Button("Forget this session") { engine.endSession(session.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text(shortPath(session.cwd)).font(.caption).foregroundStyle(.secondary)

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

                let windows = engine.usage[session.accountID]?.windows ?? []
                ForEach(windows) { window in
                    UsageBar(window: window, threshold: engine.settings.warnThresholdPercent)
                }
            }
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "busy": return .green
        case "waiting": return .orange
        default: return .secondary
        }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
