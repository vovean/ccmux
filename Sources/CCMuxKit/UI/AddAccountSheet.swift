import SwiftUI

struct AddAccountSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var loginHint = ""
    @State private var chromeProfile: String?
    @State private var kind: AccountKind = .subscription
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $kind) {
                Text("Subscription").tag(AccountKind.subscription)
                Text("API key").tag(AccountKind.apiKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .apiKey { apiKeyForm } else { subscriptionForm }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var apiKeyForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an API key").font(.headline)

            Text("Billed per token rather than against a plan. ccmux never picks an API "
                 + "key on its own — assign a session to it from the Sessions screen when "
                 + "you want to spend money on it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Name", text: $label, prompt: Text("e.g. console-key"))
                SecureField("API key", text: $apiKey, prompt: Text("sk-ant-api03-…"))
            }
            .formStyle(.grouped)
            .frame(height: 92)

            Text("The key is verified before it is stored, and kept in the Keychain — "
                 + "never in a config file or a session's environment.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(engine.loginInProgress ? "Verifying…" : "Verify and add") {
                    Task {
                        if await engine.addAPIKeyAccount(key: apiKey, label: label) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(engine.loginInProgress || apiKey.isEmpty)
            }
        }
    }

    private var subscriptionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a subscription").font(.headline)

            Text("Sign-in opens in the Chrome profile you pick, so the account that "
                 + "owns the subscription is the one that gets used.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Label (optional)", text: $label,
                          prompt: Text("e.g. max-personal"))
                TextField("Email hint (optional)", text: $loginHint,
                          prompt: Text("pre-fills the login page"))
                Picker("Chrome profile", selection: $chromeProfile) {
                    Text("Default browser").tag(String?.none)
                    ForEach(engine.chromeProfiles) { profile in
                        Text(profile.label).tag(String?.some(profile.directory))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 130)

            if !ChromeLauncher.isChromeInstalled {
                Text("Google Chrome was not found, so sign-in will use the default browser.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Import current Claude Code login") {
                    Task {
                        await engine.importGlobalLogin()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Sign in") {
                    Task {
                        await engine.beginLogin(
                            chromeProfileDirectory: chromeProfile,
                            label: label.isEmpty ? nil : label,
                            loginHint: loginHint.isEmpty ? nil : loginHint)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(engine.loginInProgress)
            }
        }
    }
}
