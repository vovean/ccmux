import SwiftUI

struct SettingsPage: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Warnings") {
                    HStack {
                        Text("Notify when headroom drops to")
                        Spacer()
                        Stepper(value: Binding(
                            get: { engine.settings.warnThresholdPercent },
                            set: { value in engine.updateSettings { $0.warnThresholdPercent = value } }),
                                in: 1...50, step: 1) {
                            Text(String(format: "%.0f%%", engine.settings.warnThresholdPercent))
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .fixedSize()
                    }
                    ForEach(UsageWindow.Kind.watchable, id: \.self) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { engine.settings.watchedWindows.contains(kind) },
                            set: { on in
                                engine.updateSettings { $0.setWatched(kind, on: on) }
                            }))
                    }
                    Toggle("Notify when an account needs re-login", isOn: Binding(
                        get: { engine.settings.notifyOnReloginNeeded },
                        set: { value in engine.updateSettings { $0.notifyOnReloginNeeded = value } }))
                }

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
                    Text("A switch takes effect on the session's next request. It also "
                         + "drops the prompt cache, so that request re-reads the whole "
                         + "conversation at full price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                        Text("No Chrome profiles found in "
                             + "~/Library/Application Support/Google/Chrome.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                section("Policies") {
                    Text("A policy is what an alias asks for. `cc-fable` needs Fable's own "
                         + "weekly window; `cc-opus` ignores it, so an account with Fable "
                         + "exhausted is still a good Opus account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(engine.settings.policies) { policy in
                        HStack(alignment: .firstTextBaseline) {
                            Text(policy.name).font(.subheadline.monospaced())
                            Spacer()
                            Text(policy.requiredWindows.map(\.displayName)
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                section("Where things live") {
                    labelledPath("State", Paths.support.path)
                    labelledPath("Log", Paths.logFile.path)
                    labelledPath("Control socket", Paths.controlSocket.path)
                }
            }
            .padding(14)
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
