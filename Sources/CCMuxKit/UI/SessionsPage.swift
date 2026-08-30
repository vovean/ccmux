import CCMuxCore
import SwiftUI

struct SessionsPage: View {
    @ObservedObject var engine: Engine
    @ObservedObject var nav: NavigationState

    private var expiredAccounts: Set<String> {
        SessionGrouping.expiredAccountIDs(in: groups, accounts: engine.accounts)
    }

    private var groups: [SessionGroup] {
        SessionGrouping.groups(accounts: engine.accounts,
                               sessions: engine.sessions,
                               unmanaged: engine.unmanagedSessions,
                               live: engine.liveByPID,
                               foreign: engine.foreignSessions)
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if engine.sessions.isEmpty {
                        EmptyHint(title: "No managed sessions",
                                  detail: engine.foreignSessions.isEmpty
                                      ? "Start one with cc-opus or cc-fable in a terminal."
                                      : "Nothing is running on this Mac. What is below is "
                                          + "running elsewhere.")
                    } else {
                        reassignBar
                    }
                    ForEach(groups) { group in
                        groupSection(group).id(group.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: Set(groups.map(\.id))) { _, ids in nav.retainOnly(ids) }
            .onAppear { bringTargetToTop(using: scroller) }
            .onChange(of: nav.scrollTarget) { _, _ in bringTargetToTop(using: scroller) }
        }
    }

    /// Arriving from an account's "N sessions" pill: the group is expanded by then, but it
    /// can sit below the fold with its sessions off-screen entirely.
    private func bringTargetToTop(using scroller: ScrollViewProxy) {
        guard let target = nav.scrollTarget else { return }
        // A target with no group would leave the request pending forever.
        guard groups.contains(where: { $0.id == target }) else {
            nav.clearScrollTarget()
            return
        }
        // One turn later: on the first appearance the rows do not have their geometry yet
        // and scrollTo lands nowhere.
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                scroller.scrollTo(target, anchor: .top)
            }
            nav.clearScrollTarget()
        }
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
                } else if expiredAccounts.contains(group.id) {
                    reloginNotice(group.id)
                } else if group.isForeignOnly && account(group.id) == nil {
                    Text("This account is not on this Mac.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    // Once per group: every session in it draws on the same quota.
                    ForEach(groupBars(group.id)) { window in
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
                if !group.foreign.isEmpty {
                    foreignDivider(group)
                    ForEach(group.foreign) { session in
                        foreignCard(session)
                    }
                }
            }
        }
    }

    /// The line between what is running here and what is not. Foreign sessions cannot be
    /// switched, ended or revealed from this Mac, so the separation is the point.
    private func foreignDivider(_ group: SessionGroup) -> some View {
        HStack(spacing: 8) {
            Text("On other Macs")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            Text("\(group.foreignCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    /// Read-only by construction: no account picker, no auto-switch, no end, no reveal.
    /// The process is on another host — every one of those controls would act on the
    /// wrong thing or on nothing.
    private func foreignCard(_ session: ForeignSession) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(session.machineLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(session.name).font(.subheadline)
                    if let status = session.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    StatusPill(text: session.policy, tint: .purple)
                    Spacer()
                    Text(activityText(session))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let directory = session.directory {
                    Text(Format.shortenHome(directory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.isStale {
                    Text("\(session.machineLabel) last reported "
                         + "\(Format.duration(session.machineAge)) ago — this may be out "
                         + "of date.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if session.spendUSD > 0 {
                    Text(Format.money(session.spendUSD))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(session.isStale ? 0.55 : 0.85)
        }
    }

    private func activityText(_ session: ForeignSession) -> String {
        let reference = session.updatedAt ?? session.startedAt
        let elapsed = Date().timeIntervalSince(reference)
        return "\(Format.duration(max(0, elapsed))) ago"
    }

    /// Re-picks accounts for running sessions the way a fresh `cc-opus` would. The
    /// counts are on the items because the useful number is how many would actually
    /// move, not how many are in scope.
    private var reassignBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Menu {
                Button(item("Idle sessions", .idle)) {
                    engine.reassignSessions(scope: .idle)
                }
                Button(item("All sessions", .all)) {
                    engine.reassignSessions(scope: .all)
                }
            } label: {
                Label("Reassign", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Move sessions to the account they would launch on now")
        }
    }

    private func item(_ title: String, _ scope: Rebalance.Scope) -> String {
        let count = engine.reassignPreview(scope: scope)
        switch count {
        case 0: return "\(title) — none to move"
        case 1: return "\(title) — 1 will move"
        default: return "\(title) — \(count) will move"
        }
    }

    /// Jumps to the tab this session is running in. Offered for unmanaged sessions too:
    /// the handle comes from the process, so ccmux does not need to have launched it.
    @ViewBuilder
    private func revealButton(_ pid: Int32) -> some View {
        if engine.canRevealInTerminal {
            Button {
                engine.revealInTerminal(pid: pid)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("Show this session's iTerm tab")
            .accessibilityLabel("Show in iTerm")
        }
    }

    /// Shown on the header so a collapsed group still says someone is waiting on you.
    private func waitingCount(_ group: SessionGroup) -> Int {
        let managed = group.sessions.filter {
            engine.claudeSession(forPID: $0.pid)?.status == "waiting"
        }.count
        return managed + group.unmanaged.filter { $0.status == "waiting" }.count
    }

    /// Shown apart from the local count, and deliberately not fed into the burger badge or
    /// a notification: a question on another Mac cannot be answered from this one, and an
    /// alert you have no way to clear is what makes people turn alerts off.
    private func foreignWaitingCount(_ group: SessionGroup) -> Int {
        group.foreign.filter { $0.status == "waiting" && !$0.isStale }.count
    }

    private func account(_ id: String) -> Account? {
        engine.accounts.first { $0.id == id }
    }

    /// The account's own ceilings, plus its budget when it has one, so a group shows the
    /// same limits the Accounts screen does without having to switch screens.
    private func groupBars(_ accountID: String) -> [UsageWindow] {
        var windows = engine.usage[accountID]?.windows ?? []
        if let account = account(accountID),
           let budget = Engine.budgetWindow(for: account) {
            windows.append(budget)
        }
        return windows
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
                if expiredAccounts.contains(group.id) { RedDot(size: 7) }
                Text(group.title).font(.subheadline.weight(.semibold))
                if let subtitle = group.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
                if group.count > 0 {
                    StatusPill(text: "\(group.count)",
                               tint: group.isUnmanaged ? .secondary : .accentColor)
                }
                if group.foreignCount > 0 {
                    StatusPill(text: "+\(group.foreignCount)", tint: .secondary)
                        .help("Running on "
                              + Set(group.foreign.map(\.machineLabel)).sorted()
                                  .joined(separator: ", "))
                }
                if waitingCount(group) > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 8))
                        Text(waitingCount(group) == 1
                             ? "1 waiting" : "\(waitingCount(group)) waiting")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                    .foregroundStyle(.orange)
                }
                if foreignWaitingCount(group) > 0 {
                    Text(foreignWaitingCount(group) == 1
                         ? "1 waiting elsewhere"
                         : "\(foreignWaitingCount(group)) waiting elsewhere")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.10)))
                        .foregroundStyle(.orange.opacity(0.75))
                }
                if let account = account(group.id), account.kind == .apiKey {
                    Text(Format.money(engine.liveSpend(forAccount: account.id)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text("live · \(Format.money(account.spendLifetimeUSD)) total")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.count) sessions")
        .accessibilityHint(collapsed ? "Expand" : "Collapse")
    }

    /// The sign-in is gone, so nothing in this group can run until it is renewed — and
    /// the button is here so renewing it does not mean hunting for another screen.
    private func reloginNotice(_ accountID: String) -> some View {
        let account = engine.accounts.first { $0.id == accountID }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sign-in expired — these sessions cannot run.")
                    .font(.caption)
                    .foregroundStyle(.red)
                if let detail = account?.healthDetail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Sign in again") { engine.relogin(accountID: accountID) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(engine.loginInProgress)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.red.opacity(0.10)))
    }

    private func unmanagedCard(_ info: ClaudeSessionInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.name ?? "claude").font(.subheadline)
                    if info.status == "waiting" {
                        waitingLabel
                    } else if let status = info.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    Spacer()
                    revealButton(info.pid)
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
                    if blocked != nil || engine.unreachableSessions.contains(session.id) {
                        RedDot()
                    }
                    Text(info?.name ?? Format.shortenHome(session.cwd)).font(.headline)
                    if info?.status == "waiting" {
                        waitingLabel
                    } else if let status = info?.status {
                        StatusPill(text: status, tint: statusTint(status))
                    }
                    StatusPill(text: session.policyName, tint: .purple)
                    Spacer()
                    revealButton(session.pid)
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

                if engine.unreachableSessions.contains(session.id) {
                    Text("Port \(String(session.port)) is held by something else, so this "
                         + "session's requests are failing. ccmux retries every few "
                         + "seconds and it resumes on its own once the port frees.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                    if session.spendUSD > 0 {
                        Text(Format.money(session.spendUSD))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .help("Spent by this session")
                    }
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

    /// A blocked session is asking a question and will sit there until it is answered,
    /// which is worth more than the word "waiting" in a grey pill.
    private var waitingLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.raised.fill").font(.system(size: 9))
            Text("waiting for you")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.22)))
        .foregroundStyle(.orange)
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "busy": return .green
        case "waiting": return .orange
        default: return .secondary
        }
    }

}
