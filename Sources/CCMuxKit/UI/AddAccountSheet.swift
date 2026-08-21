import SwiftUI

struct AddAccountSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var loginHint = ""
    @State private var chromeProfile: String?

    var body: some View {
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
        .padding(18)
        .frame(width: 460)
    }
}
