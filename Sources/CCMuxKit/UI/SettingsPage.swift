import AppKit
import SwiftUI

struct SettingsPage: View {
    @ObservedObject var engine: Engine
    @State private var proxyText = ""
    @State private var proxyTesting = false
    @State private var proxyResult: String?
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                warnings
                exhaustion
                limitWindows
                signInBrowser
                upstreamProxySection
                policies
                directoryBindings
                transfer
                paths
            }
            .padding(14)
        }
        .sheet(isPresented: $exporting) {
            ExportSheet(engine: engine) { exporting = false }
        }
        .sheet(isPresented: $importing) {
            ImportSheet(engine: engine) { importing = false }
        }
    }

    /// Setting up a second Mac. The sign-ins cannot travel — see `AccountBundle` — so
    /// this carries everything else and walks the rest.
    @ViewBuilder
    private var transfer: some View {
        section("Another Mac") {
            Text("Export what this Mac knows — accounts, their order, their Chrome "
                 + "profiles — and import it there. Subscription sign-ins are not "
                 + "included: each Mac needs its own, and the import walks you through "
                 + "them, skipping any account already set up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export…") { exporting = true }
                Button("Import…") { importing = true }
                Spacer()
            }
            .controlSize(.small)
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

    /// Connectors an admin approves live on an Anthropic organization, and Claude Code
    /// reads the list once at startup from whichever account it launched on. Binding a
    /// project to an account is what makes that come out right without a flag.
    @ViewBuilder
    private var directoryBindings: some View {
        section("Project accounts") {
            Text("A session started in one of these directories launches on the account "
                 + "named here, or another account in the same organization. This applies "
                 + "at launch only — the session still rotates for quota afterwards, and "
                 + "keeps the connectors its organization approved when it does.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(engine.settings.directoryBindings) { binding in
                bindingRow(binding)
            }
            if engine.settings.directoryBindings.isEmpty {
                Text("No directories bound. Every session launches on whichever account "
                     + "its policy ranks first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Bind a directory…") { chooseDirectory() }
                    .controlSize(.small)
                    .disabled(DirectoryBindings.bindable(engine.accounts).isEmpty)
            }
        }
    }

    private func bindingRow(_ binding: DirectoryBinding) -> some View {
        HStack(spacing: 8) {
            Text(Format.shortenHome(binding.path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { binding.accountID },
                set: { engine.bindDirectory(binding.path, to: $0) })) {
                // API keys are absent on purpose: a binding must not be a way to spend
                // money on every session started in a directory.
                ForEach(DirectoryBindings.bindable(engine.accounts)) { account in
                    Text(account.organizationName ?? account.displayName).tag(account.id)
                }
                // A rule naming an account that has since been removed stays visible and
                // selectable rather than silently snapping to a different organization.
                if !engine.accounts.contains(where: { $0.id == binding.accountID }) {
                    Text("removed account").tag(binding.accountID)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            Button {
                engine.unbindDirectory(binding.path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove this binding")
        }
    }

    private func chooseDirectory() {
        guard let account = DirectoryBindings.bindable(engine.accounts).first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bind"
        panel.message = "Sessions started in this directory launch on the account you pick."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.bindDirectory(url.path, to: account.id)
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
