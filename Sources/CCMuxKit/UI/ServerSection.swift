import CCMuxCore
import SwiftUI

/// Settings → Account server. Three states: not connected, confirming a certificate, and
/// connected with a plan to apply.
struct ServerSection: View {
    @ObservedObject var engine: Engine

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    /// Set once the handshake has happened and the user has yet to agree to it. Holding
    /// it here rather than in settings is what makes confirmation mandatory.
    @State private var pendingFingerprint: String?
    @State private var failure: String?
    @State private var pushSelection: Set<String> = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Account server").font(.headline)
                Text("Keeps every account and its refresh lineage in one place, so a new "
                     + "Mac imports them instead of signing in to all of them again. It "
                     + "hands out short-lived tokens only — inference still goes straight "
                     + "from this Mac to Anthropic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let connection = engine.settings.server {
                    connected(connection)
                } else if let pendingFingerprint {
                    confirm(pendingFingerprint)
                } else {
                    disconnected
                }

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Not connected

    @ViewBuilder
    private var disconnected: some View {
        TextField("ccmux.example.com  or  203.0.113.10:8443", text: $urlText)
            .textFieldStyle(.roundedBorder)
        HStack(spacing: 8) {
            TextField("username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            SecureField("password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Button(engine.serverBusy ? "Connecting…" : "Connect") { Task { await probe() } }
                .disabled(engine.serverBusy || urlText.trimmingCharacters(in: .whitespaces)
                              .isEmpty || username.isEmpty || password.isEmpty)
            Spacer()
        }
        Text("The password is stored in the Keychain, never in settings.json.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Confirming the certificate

    @ViewBuilder
    private func confirm(_ fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Is this your server?").font(.subheadline.weight(.semibold))
            Text(ServerFingerprint.display(fingerprint))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // The certificate is self-signed, so no authority vouches for it. Matching
            // this against what the server printed at install time is the only check
            // there is — and it is checked again on every later request.
            Text("Self-signed, so nothing else vouches for it. Compare it with what "
                 + "install-ccmuxd.sh printed. ccmux will refuse to talk to anything "
                 + "presenting a different certificate from now on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Trust and connect") { Task { await connect(fingerprint) } }
                    .disabled(engine.serverBusy)
                Button("Cancel") {
                    pendingFingerprint = nil
                    password = ""
                }
                Spacer()
            }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private func connected(_ connection: ServerConnection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).font(.caption)
            Text(connection.url).font(.caption.monospaced())
            Text("· \(connection.username)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        Text("pinned \(ServerFingerprint.short(connection.fingerprint))")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        let delegated = engine.settings.delegatedAccountIDs.count
        if delegated > 0 {
            Text("\(delegated) account(s) delegated — this Mac holds no refresh token for "
                 + "them and asks the server for tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let plan = engine.delegationPlan, !plan.isEmpty {
            planView(plan)
        }

        HStack(spacing: 8) {
            Button("Check for changes") { Task { await engine.refreshDelegationPlan() } }
                .disabled(engine.serverBusy)
            Button("Disconnect") { engine.disconnectServer() }
            Spacer()
        }
    }

    @ViewBuilder
    private func planView(_ plan: Delegation.Plan) -> some View {
        Divider()
        let taking = plan.entries(.delegate)
        let importing = plan.entries(.importable)
        let pushable = plan.entries(.pushCandidate)

        VStack(alignment: .leading, spacing: 6) {
            if !taking.isEmpty {
                row("Hand over to the server", taking.map(\.displayName),
                    "The server already has these. This Mac stops refreshing them.")
            }
            if !importing.isEmpty {
                row("Import from the server", importing.map(\.displayName),
                    "Not on this Mac yet.")
            }
            if !pushable.isEmpty {
                Text("Not on the server yet").font(.caption.weight(.semibold))
                ForEach(pushable) { entry in
                    Toggle(isOn: Binding(
                        get: { pushSelection.contains(entry.id) },
                        set: { on in
                            if on { pushSelection.insert(entry.id) }
                            else { pushSelection.remove(entry.id) }
                        })) {
                            Text(entry.displayName).font(.caption)
                        }
                        .toggleStyle(.checkbox)
                }
                // Pushing is the one direction a refresh token travels, so it is opt-in
                // per account rather than a default.
                Text("Pushing uploads that account's refresh token to the server.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button(engine.serverBusy ? "Working…" : "Apply") {
                Task {
                    await engine.applyDelegation(pushing: pushSelection)
                    pushSelection = []
                }
            }
            .disabled(engine.serverBusy)
        }
    }

    private func row(_ title: String, _ names: [String], _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(names.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func probe() async {
        failure = nil
        switch await engine.probeServer(urlText) {
        case .success(let fingerprint):
            pendingFingerprint = fingerprint
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    private func connect(_ fingerprint: String) async {
        failure = await engine.connectServer(url: urlText, username: username,
                                             password: password, fingerprint: fingerprint)
        if failure == nil {
            pendingFingerprint = nil
            password = ""
        }
    }
}
