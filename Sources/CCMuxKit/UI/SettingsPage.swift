import SwiftUI

struct SettingsPage: View {
    @ObservedObject var engine: Engine
    @State private var proxyText = ""
    @State private var proxyTesting = false
    @State private var proxyResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                warnings
                exhaustion
                limitWindows
                signInBrowser
                upstreamProxySection
                policies
                paths
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        section("Warnings") {
            HStack {
                Text("Notify when headroom drops to")
                Spacer()
                Stepper(value: Binding(
                    get: { engine.settings.warnThresholdPercent },
                    set: { value in
                        engine.updateSettings { $0.warnThresholdPercent = value }
                    }), in: 1...50, step: 1) {
                    Text(String(format: "%.0f%%", engine.settings.warnThresholdPercent))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .fixedSize()
            }
            ForEach(UsageWindow.Kind.watchable, id: \.self) { kind in
                Toggle(kind.displayName, isOn: Binding(
                    get: { engine.settings.watchedWindows.contains(kind) },
                    set: { on in engine.updateSettings { $0.setWatched(kind, on: on) } }))
            }
            Toggle("Notify when an account needs re-login", isOn: Binding(
                get: { engine.settings.notifyOnReloginNeeded },
                set: { value in
                    engine.updateSettings { $0.notifyOnReloginNeeded = value }
                }))
        }
    }

    @ViewBuilder
    private var exhaustion: some View {
        section("When an account runs out") {
            Picker("Auto-switch", selection: Binding(
                get: { engine.settings.autoSwitch },
                set: { value in engine.updateSettings { $0.autoSwitch = value } })) {
                ForEach(AutoSwitchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Notify when a session is moved", isOn: Binding(
                get: { engine.settings.notifyOnAutoSwitch },
                set: { value in engine.updateSettings { $0.notifyOnAutoSwitch = value } }))
            Text("""
                A refusal is retried on another account before Claude Code sees it, so a \
                session keeps going. A switch drops the prompt cache, so the next request \
                re-reads the conversation at full price.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var limitWindows: some View {
        section("Limit windows") {
            Toggle("Keep the 5-hour window rolling while idle", isOn: Binding(
                get: { engine.settings.keepWindowsRolling },
                set: { value in engine.updateSettings { $0.keepWindowsRolling = value } }))
            Text("""
                The 5-hour window starts on first use, not on a clock. When an account's \
                is stopped, ccmux sends one minimal Haiku request to start it, so the \
                cycle keeps turning while you are away and there is less of it left to \
                wait out when you come back. About 20 tokens per account per cycle, and \
                it does not touch the Fable or Opus weekly windows.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var signInBrowser: some View {
        section("Sign-in browser") {
            Text("Which Chrome profile each account's login page opens in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if engine.accounts.isEmpty {
                Text("No accounts yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(engine.accounts) { account in
                HStack {
                    Text(account.displayName)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { account.chromeProfileDirectory },
                        set: { engine.setChromeProfile($0, for: account.id) })) {
                        Text("Default browser").tag(String?.none)
                        ForEach(engine.chromeProfiles) { profile in
                            Text(profile.label).tag(String?.some(profile.directory))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
            }
            if engine.chromeProfiles.isEmpty {
                Text("No Chrome profiles found in ~/Library/Application Support/Google/Chrome.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var policies: some View {
        section("Policies") {
            Text("""
                A policy is what an alias asks for. cc-fable needs Fable's own weekly \
                window; cc-opus ignores it, so an account with Fable exhausted is still a \
                good Opus account. Among the accounts that qualify, the most drained one \
                is picked, so a subscription is finished before the next is started on.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(engine.settings.policies) { policy in
                policyRow(policy)
            }
        }
    }

    private func policyRow(_ policy: Policy) -> some View {
        let floors = UsageWindow.Kind.watchable
            .filter { policy.floor(for: $0) > 0 }
            .map { "\($0.displayName) ≥ \(Int(policy.floor(for: $0)))%" }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(policy.name).font(.subheadline.monospaced())
                Spacer()
                Text(policy.requiredWindows.map(\.displayName).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !floors.isEmpty {
                Text("starts only on: " + floors.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var paths: some View {
        section("Where things live") {
            labelledPath("State", Paths.support.path)
            labelledPath("Log", Paths.logFile.path)
            labelledPath("Control socket", Paths.controlSocket.path)
        }
    }

    private func labelledPath(_ title: String, _ path: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(Format.shortenHome(path))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder
    private var upstreamProxySection: some View {
        section("Outbound proxy") {
            Text("Sends everything ccmux talks to Anthropic through an HTTP proxy — "
                 + "inference, token refresh, usage and probes alike. This affects ccmux "
                 + "only: it does not change system proxy settings, routing, or how any "
                 + "other program reaches the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let proxy = engine.settings.upstreamProxy {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(proxy.displayString)
                        .font(.caption.monospaced())
                    if proxy.username != nil {
                        Text("· password in Keychain")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                TextField("http://user:password@host:3128", text: $proxyText)
                    .textFieldStyle(.roundedBorder)
                Button("Use") {
                    if engine.setUpstreamProxy(proxyText) {
                        proxyText = ""
                        proxyResult = nil
                    }
                }
                .disabled(proxyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 8) {
                Button(proxyTesting ? "Testing…" : "Test") {
                    proxyTesting = true
                    proxyResult = nil
                    Task {
                        proxyResult = await engine.testUpstreamProxy()
                        proxyTesting = false
                    }
                }
                .disabled(proxyTesting || engine.settings.upstreamProxy == nil)
                Button("Stop using a proxy") {
                    engine.clearUpstreamProxy()
                    proxyResult = nil
                }
                .disabled(engine.settings.upstreamProxy == nil)
                Spacer()
            }

            if let proxyResult {
                Text(proxyResult)
                    .font(.caption)
                    .foregroundStyle(proxyResult.hasPrefix("Proxy failed") ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The password is stored in the Keychain, never in settings.json. "
                 + "Existing sessions pick the change up on their next request.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
