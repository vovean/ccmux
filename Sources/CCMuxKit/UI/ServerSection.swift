import CCMuxCore
import SwiftUI

/// Settings → Account server. Three states: not connected, confirming a certificate, and
/// connected with a plan to apply.
struct ServerSection: View {
    @ObservedObject var engine: Engine

    @State private var urlText = ""
    @State private var editingAddresses = false
    @State private var addressText = ""
    @State private var addressError: String?
    @State private var username = ""
    @State private var password = ""
    /// Set once the handshake has happened and the user has yet to agree to it. Holding
    /// it here rather than in settings is what makes confirmation mandatory.
    @State private var pendingFingerprint: String?
    @State private var failure: String?
    @State private var pushSelection: Set<String> = []
    @State private var machineLabel = ""

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
        TextField("ccmux.example.com  or  203.0.113.10:8443, 10.0.0.1", text: $urlText)
            .textFieldStyle(.roundedBorder)
        Text("Several addresses for the same server, separated by commas, are tried in "
             + "turn — useful when it is reachable at one address over a tunnel and "
             + "another without. They all have to present the same certificate.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
        if !connection.alternateURLs.isEmpty {
            // Named rather than merely counted: which address is in use says which network
            // this Mac is on, and that is the first thing worth knowing when it stops
            // working.
            Text("also tries " + connection.alternateURLs.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editingAddresses {
            HStack(spacing: 8) {
                TextField("10.0.0.1, 203.0.113.10:8443", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    addressError = engine.setServerAddresses(addressText)
                    if addressError == nil { editingAddresses = false }
                }
                .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { editingAddresses = false; addressError = nil }
            }
            if let addressError {
                Text(addressError).font(.caption).foregroundStyle(.red)
            }
            Text("The certificate is not re-confirmed: every address is checked against "
                 + "the pin already agreed, so one that answers with anything else is "
                 + "refused.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button("Edit addresses") {
                addressText = connection.addresses.joined(separator: ", ")
                addressError = nil
                editingAddresses = true
            }
            .font(.caption)
            .buttonStyle(.link)
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

        sessionSharing

        HStack(spacing: 8) {
            Button("Check for changes") { Task { await engine.refreshDelegationPlan() } }
                .disabled(engine.serverBusy)
            Button("Disconnect") { engine.disconnectServer() }
            Spacer()
        }
    }

    // MARK: - Sessions across machines

    private static let syncBlurb =
        "Writes ~/.claude/hooks/managed and nothing else."
    private static let syncBlurbOldServer =
        " This server is too old to serve them."
    /// Spelled out because it is the one switch that lets a background tick make this Mac
    /// run something it has never run before.
    private static let registerBlurb =
        "Off by default. On, ccmux edits the hooks section of ~/.claude/settings.json to "
        + "match whichever scripts are marked active on the Hooks screen — so a script "
        + "published centrally starts running here on its own. It only ever touches "
        + "entries pointing inside hooks/managed, and turning this off removes them "
        + "again. Claude Code reads hooks at startup, so changes reach new sessions only."

    @ViewBuilder
    private var managedHooks: some View {
        Toggle("Sync hook scripts from the server", isOn: Binding(
            get: { engine.settings.syncManagedHooks },
            set: { engine.setSyncManagedHooks($0) }))
            .toggleStyle(.checkbox)
            .font(.caption)
        blurb(Self.syncBlurb
            + (engine.serverSupportsHooks == false ? Self.syncBlurbOldServer : ""))

        Toggle("Register active hooks with Claude Code", isOn: Binding(
            get: { engine.settings.registerManagedHooks },
            set: { engine.setRegisterManagedHooks($0) }))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(!engine.settings.syncManagedHooks)
        blurb(Self.registerBlurb)
    }

    private func blurb(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sessionSharing: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions on other Macs").font(.caption.weight(.semibold))

            if engine.serverSupportsSessions == false {
                Text("This ccmuxd predates session sharing — upgrade the server and it "
                     + "starts working on its own.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            managedHooks

            Toggle("Show sessions from other Macs", isOn: Binding(
                get: { engine.settings.showForeignSessions },
                set: { engine.setShowForeignSessions($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            // Display only, and said so plainly: turning it off here and having this Mac
            // vanish from every other window would read as the feature being broken.
            Text("This Mac keeps reporting its own sessions either way, so the others "
                 + "still see it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("This Mac is called").font(.caption).foregroundStyle(.secondary)
                TextField("name", text: $machineLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    // Return goes through the same predicate as the button. Without it,
                    // Return on an empty field renamed the Mac to its computer name while
                    // the field still read empty.
                    .onSubmit { saveMachineLabel() }
                Button("Save") { saveMachineLabel() }
                    .controlSize(.small)
                    .disabled(!canSaveMachineLabel)
                Spacer()
            }

            ForEach(engine.foreignMachines, id: \.id) { machine in
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(machine.label).font(.caption)
                    let current = machine.ageSeconds <= ForeignSessions.currentWithin
                    Text(current ? "now"
                         : "last seen \(Format.duration(machine.ageSeconds)) ago")
                        .font(.caption2)
                        .foregroundStyle(current ? Color.secondary : Color.orange)
                    Spacer()
                    // For a Mac that is gone for good; one still running reports itself
                    // back on its next tick.
                    Button("Forget") { Task { await engine.forgetMachine(machine.id) } }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { machineLabel = engine.machineIdentity.label }
    }

    private var canSaveMachineLabel: Bool {
        let trimmed = machineLabel.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != engine.machineIdentity.label
    }

    /// Echoes back what was actually stored — the label is trimmed on the way in, so a
    /// name typed with stray spaces would otherwise leave Save enabled for a rename that
    /// had already happened.
    private func saveMachineLabel() {
        guard canSaveMachineLabel else { return }
        engine.setMachineLabel(machineLabel)
        machineLabel = engine.machineIdentity.label
    }

    @ViewBuilder
    private func planView(_ plan: Delegation.Plan) -> some View {
        Divider()
        let taking = plan.entries(.delegate)
        let importing = plan.entries(.importable)
        let pushable = plan.entries(.pushCandidate)
        let stranded = plan.entries(.serverNeedsRelogin)

        VStack(alignment: .leading, spacing: 6) {
            if !taking.isEmpty {
                row("Hand over to the server", taking.map(\.displayName),
                    "The server already has these. This Mac stops refreshing them.")
            }
            if !importing.isEmpty {
                row("Import from the server", importing.map(\.displayName),
                    "Not on this Mac yet.")
            }
            if !stranded.isEmpty {
                row("The server needs signing in again for these",
                    stranded.map(\.displayName),
                    "Left alone — handing over to a dead lineage would trade a working "
                        + "credential for a broken one. Sign them in from any connected Mac.")
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
