import SwiftUI

public enum Page: String, CaseIterable, Identifiable {
    case accounts, sessions, settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.2"
        case .sessions: return "terminal"
        case .settings: return "gearshape"
        }
    }
}

public struct RootView: View {
    @ObservedObject var engine: Engine
    @State private var page: Page = .accounts
    @State private var curtainOpen = false

    public init(engine: Engine) {
        self.engine = engine
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                Divider()
                if let banner = engine.banner { bannerView(banner) }
                content
            }

            if curtainOpen {
                // The scrim closes the curtain on any outside click, which is the only
                // dismissal gesture a drawer really needs.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { curtainOpen = false } }
                    .transition(.opacity)
                curtain
                    .transition(.move(edge: .leading))
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { curtainOpen.toggle() }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 22)
                    if engine.needsAttention {
                        RedDot().offset(x: 3, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(engine.needsAttention
                  ? "An account needs attention" : "Menu")
            .accessibilityLabel("Menu")

            Text(page.title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .accounts: AccountsPage(engine: engine)
        case .sessions: SessionsPage(engine: engine)
        case .settings: SettingsPage(engine: engine)
        }
    }

    private var curtain: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ccmux")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(Page.allCases) { entry in
                Button {
                    page = entry
                    withAnimation(.easeOut(duration: 0.15)) { curtainOpen = false }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: entry.icon)
                            .frame(width: 18)
                        Text(entry.title)
                        Spacer()
                        if entry == .accounts && engine.needsAttention { RedDot() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(page == entry
                                ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if engine.needsAttention {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(engine.accountsNeedingAttention) { account in
                        HStack(spacing: 6) {
                            RedDot(size: 6)
                            Text("\(account.displayName) needs re-login")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Divider() }
    }

    private func bannerView(_ banner: Engine.Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.level == .warning
                  ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(banner.level == .warning ? .orange : .secondary)
            Text(banner.text).font(.callout)
            Spacer()
            if banner.action == .openNotificationSettings {
                Button("Open Settings") { engine.openNotificationSettings() }
                    .controlSize(.small)
            }
            Button {
                engine.dismissBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(banner.level == .warning
                    ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.10))
    }
}
