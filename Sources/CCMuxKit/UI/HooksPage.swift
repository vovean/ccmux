import CCMuxCore
import SwiftUI

/// The managed hook set: what each script is, what it says, and which way a disagreement
/// with the server should be settled.
struct HooksPage: View {
    @ObservedObject var engine: Engine
    @State private var expanded: Set<String> = []
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if engine.hookStatus.hooks.isEmpty {
                    EmptyHint(title: "No managed hooks",
                              detail: engine.settings.server == nil
                                  ? "Connect an account server in Settings and the hooks it "
                                      + "holds appear here."
                                  : "The server is not publishing any hook scripts yet.")
                } else {
                    ForEach(engine.hookStatus.hooks) { hook in
                        row(hook)
                    }
                }
            }
            .padding(14)
        }
        .task { await engine.loadHooksFromDisk() }
    }

    // MARK: - Summary

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Managed hooks").font(.headline)
                    Spacer()
                    StatusPill(text: summaryText, tint: summaryTint)
                }
                Text(Format.shortenHome(ManagedHooks.root.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !engine.settings.syncManagedHooks {
                    Text("Syncing is off in Settings, so this list is whatever is already "
                         + "on disk.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if engine.hookStatus.frozen {
                    // Stated plainly, because the consequence is invisible otherwise: a
                    // hook published centrally will not arrive until this clears.
                    Text("Syncing is on hold. Nothing is written to this directory — "
                         + "including hooks other Macs have already picked up — until "
                         + "every local change below is settled.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let checked = engine.hookStatus.checkedAt {
                    Text("Server checked "
                         + "\(Format.duration(Date().timeIntervalSince(checked))) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("The server has not been reached yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var summaryText: String {
        let status = engine.hookStatus
        if status.frozen { return "\(status.undecided.count) need you" }
        if status.hooks.contains(where: { $0.state == .unknown }) { return "not checked" }
        if status.hooks.contains(where: { $0.state == .stale }) { return "updating" }
        return "in sync"
    }

    private var summaryTint: Color {
        if engine.hookStatus.frozen { return .orange }
        if engine.hookStatus.hooks.contains(where: { $0.state == .unknown }) {
            return .secondary
        }
        return .green
    }

    // MARK: - One hook

    private func row(_ hook: ManagedHook) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        toggle(hook.path)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded.contains(hook.path)
                                  ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 10)
                            Text(name(of: hook.path)).font(.body.weight(.medium))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    StatusPill(text: label(hook.state), tint: tint(hook.state))
                }

                Button {
                    note = EditorOpener.open(url(of: hook)).message
                } label: {
                    Text(Format.shortenHome(url(of: hook).path))
                        .font(.caption.monospaced())
                        .foregroundStyle(hook.local == nil ? Color.secondary : Color.accentColor)
                        .underline(hook.local != nil)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hook.local == nil)
                .help(hook.local == nil ? "Not written to this Mac yet"
                                        : "Open in VS Code")

                HStack(spacing: 8) {
                    Text(detail(hook))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if hook.needsDecision { decisionButtons(hook) }
                }

                if expanded.contains(hook.path) { script(hook) }
            }
        }
    }

    @ViewBuilder
    private func decisionButtons(_ hook: ManagedHook) -> some View {
        Button("Upload") { Task { await engine.resolveHook(hook.path, .takeLocal) } }
            .controlSize(.small)
            .help("Publish this Mac's copy to the server, leaving every other hook alone")
        Button(hook.server == nil ? "Delete" : "Download") {
            Task { await engine.resolveHook(hook.path, .takeServer) }
        }
        .controlSize(.small)
        .help(hook.server == nil
              ? "The server does not have this file — remove it from this Mac"
              : "Overwrite this Mac's copy with the server's")
    }

    @ViewBuilder
    private func script(_ hook: ManagedHook) -> some View {
        if let body = hook.body, !body.isEmpty {
            ScrollView(.horizontal) {
                highlighted(body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        } else {
            Text(hook.body == nil ? "Nothing to show." : "Empty file.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func highlighted(_ source: String) -> Text {
        ShellSyntax.highlight(source).reduce(Text("")) { text, run in
            text + Text(run.text).foregroundColor(colour(run.kind))
        }
    }

    private func colour(_ kind: ShellSyntax.Kind) -> Color {
        switch kind {
        case .plain: return .primary
        case .comment: return .secondary
        case .string: return Color(nsColor: .systemBrown)
        case .keyword: return Color(nsColor: .systemPurple)
        case .variable: return Color(nsColor: .systemTeal)
        }
    }

    // MARK: - Labels

    private func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    private func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func url(of hook: ManagedHook) -> URL {
        ManagedHooks.root.appendingPathComponent(hook.path)
    }

    private func label(_ state: ManagedHook.State) -> String {
        switch state {
        case .inSync: return "in sync"
        case .stale: return "updating"
        case .editedHere: return "edited here"
        case .conflict: return "conflict"
        case .unknown: return "not checked"
        }
    }

    private func tint(_ state: ManagedHook.State) -> Color {
        switch state {
        case .inSync: return .green
        case .stale: return .blue
        case .editedHere: return .orange
        case .conflict: return .red
        case .unknown: return .secondary
        }
    }

    private func detail(_ hook: ManagedHook) -> String {
        switch hook.state {
        case .inSync, .unknown:
            guard let synced = hook.syncedAt else { return "Never synced" }
            return "Synced \(Format.duration(Date().timeIntervalSince(synced))) ago"
        case .stale:
            if hook.local == nil { return "Arriving from the server" }
            if hook.server == nil { return "Withdrawn on the server — will be removed" }
            return "Newer on the server — arriving"
        case .editedHere:
            return hook.server == nil
                ? "Written on this Mac, never published"
                : "Changed on this Mac"
        case .conflict:
            return hook.server == nil
                ? "Changed here, withdrawn on the server"
                : "Changed here and on the server"
        }
    }
}
