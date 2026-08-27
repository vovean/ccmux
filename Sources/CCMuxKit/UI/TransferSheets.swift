import AppKit
import SwiftUI

/// Choosing what leaves this Mac, and where the file goes.
struct ExportSheet: View {
    @ObservedObject var engine: Engine
    var dismiss: () -> Void

    @State private var includePolicies = true
    @State private var includeSecrets = false
    @State private var error: String?

    private var keyCount: Int {
        engine.accounts.filter { $0.kind == .apiKey }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export accounts").font(.headline)

            Text("Subscription sign-ins are never written to the file. Two machines "
                 + "sharing one sign-in invalidate each other's, so each Mac signs in for "
                 + "itself — the export carries everything else, and the import walks you "
                 + "through the sign-ins that are left.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                row("\(engine.accounts.count) account(s)",
                    detail: "Names, organizations, order, rotation and budgets.",
                    always: true)
                Toggle(isOn: $includePolicies) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Policies and thresholds")
                        Text("cc-opus and cc-fable definitions, launch floors, warning "
                             + "thresholds, auto-switch mode.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $includeSecrets) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(keyCount == 1 ? "Include the API key"
                                           : "Include \(keyCount) API keys")
                        Text(keyCount == 0
                             ? "No API-key accounts to include."
                             : "Written in plain text. The file becomes a live "
                                + "credential — move it and then delete it.")
                            .font(.caption2)
                            .foregroundStyle(includeSecrets && keyCount > 0
                                             ? .orange : .secondary)
                    }
                }
                .disabled(keyCount == 0)
            }

            Text("Project bindings and the outbound proxy stay behind: bindings name "
                 + "paths that may not exist there, and the proxy is per-network.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Save…") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func row(_ title: String, detail: String, always: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ccmux-accounts.json"
        panel.allowedContentTypes = [.json]
        panel.message = includeSecrets
            ? "This file will contain an API key in plain text."
            : "Contains no credentials."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = engine.exportBundle(includePolicies: includePolicies,
                                             includeSecrets: includeSecrets)
            try engine.write(bundle, to: url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Walks the accounts that are missing on this Mac, one sign-in at a time.
struct ImportSheet: View {
    @ObservedObject var engine: Engine
    var dismiss: () -> Void

    @State private var bundle: AccountBundle?
    @State private var plan: AccountTransfer.Plan?
    @State private var busy: String?
    @State private var note: String?
    @State private var keyEntry: [String: String] = [:]
    @State private var applySettings = false
    @State private var settingsApplied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import accounts").font(.headline)

            if let plan {
                planView(plan)
            } else {
                Text("Choose the file exported from your other Mac. Nothing already set "
                     + "up here will be changed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss)
                    Button("Choose file…") { choose() }.buttonStyle(.borderedProminent)
                }
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    @ViewBuilder
    private func planView(_ plan: AccountTransfer.Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.steps) { step in
                    stepRow(step)
                }
            }
        }
        .frame(maxHeight: 280)

        if let bundle, bundle.policies != nil || bundle.thresholds != nil {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Also replace this Mac's policies and thresholds",
                       isOn: $applySettings)
                    .disabled(settingsApplied)
                Text(settingsApplied
                     ? "Applied."
                     : "Off by default: this replaces your policies outright, and a "
                        + "policy an alias here depends on would stop existing.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if applySettings && !settingsApplied {
                    Button("Replace them now") {
                        engine.applyImportedSettings(bundle)
                        settingsApplied = true
                        note = "Policies and thresholds replaced."
                    }
                    .controlSize(.small)
                }
            }
        }

        if !engine.pendingProfileNames.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Chrome profiles waiting for a name: "
                     + engine.pendingProfileNames.joined(separator: ", "))
                    .font(.caption)
                Text("Chrome rewrites its profile list when it exits, so names can only "
                     + "be set while it is closed.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Quit Chrome, then name them") {
                    note = engine.nameImportedProfiles()
                }
                .controlSize(.small)
            }
        }

        HStack {
            Spacer()
            Button("Done", action: dismiss).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func stepRow(_ step: AccountTransfer.Step) -> some View {
        // An imported API key gets an id of its own, so "did this entry produce an
        // account" is the question, not "is there an account with this id".
        let done = step.disposition == .present
            || engine.importedIDs[step.entry.id] != nil
            || engine.accounts.contains { $0.id == step.entry.id }
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.entry.displayName)
                HStack(spacing: 6) {
                    Text(step.disposition.summary)
                    if let profile = step.entry.chromeProfileName, !done {
                        Text("· Chrome profile “\(profile)”")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                switch step.disposition {
                case .signIn:
                    Button(busy == step.entry.id ? "Signing in…" : "Sign in") {
                        signIn(step.entry)
                    }
                    .controlSize(.small)
                    .disabled(busy != nil || engine.loginInProgress)
                case .addKey:
                    Button("Add") { addKey(step.entry, key: step.entry.apiKey ?? "") }
                        .controlSize(.small)
                        .disabled(busy != nil)
                case .needsKey:
                    SecureField("sk-ant-…", text: Binding(
                        get: { keyEntry[step.entry.id] ?? "" },
                        set: { keyEntry[step.entry.id] = $0 }))
                        .frame(width: 150)
                    Button("Add") {
                        addKey(step.entry, key: keyEntry[step.entry.id] ?? "")
                    }
                    .controlSize(.small)
                    .disabled((keyEntry[step.entry.id] ?? "").isEmpty || busy != nil)
                case .present:
                    EmptyView()
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try engine.readBundle(from: url)
            guard loaded.version <= AccountBundle.currentVersion else {
                note = "That file was written by a newer ccmux. Upgrade this one first."
                return
            }
            bundle = loaded
            plan = engine.importPlan(loaded)
            let present = plan?.present.count ?? 0
            note = present > 0
                ? "\(present) account(s) are already set up here and were left alone."
                : nil
        } catch {
            note = "Could not read that file: \(error.localizedDescription)"
        }
    }

    private func signIn(_ entry: AccountBundle.Entry) {
        busy = entry.id
        Task {
            _ = await engine.importSignIn(entry)
            busy = nil
            if let bundle { plan = engine.importPlan(bundle) }
        }
    }

    private func addKey(_ entry: AccountBundle.Entry, key: String) {
        busy = entry.id
        Task {
            let ok = await engine.importAPIKey(entry, key: key)
            busy = nil
            if !ok { note = "That key was refused by the API." }
            if let bundle { plan = engine.importPlan(bundle) }
        }
    }
}
