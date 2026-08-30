import CCMuxCore
import SwiftUI

/// The one place a sign-in is visible while it is happening.
///
/// Three things it always offers, because their absence is what made the old flow stick:
/// a way to paste the code when the browser cannot hand it back, a way to start over, and
/// a way out that takes effect immediately.
struct LoginSheet: View {
    @ObservedObject var engine: Engine
    let attempt: LoginAttempt

    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(attempt.title).font(.headline)

            status

            if let note = attempt.launchNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if attempt.acceptsCode { pasteSection }

            Divider()

            HStack(spacing: 8) {
                if attempt.isBusy {
                    Button("Open the browser again") { engine.reopenLoginBrowser() }
                }
                Button("Start over") { engine.restartLogin() }
                Spacer()
                Button(attempt.isSucceeded ? "Done" : "Cancel") {
                    engine.cancelLogin()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        // Closing by any route abandons the attempt, so nothing is left half-armed.
        // Scoped to this attempt: Start over swaps the sheet's identity, and a nil check
        // would let the outgoing view cancel the attempt that just replaced it.
        .onDisappear { if engine.loginAttempt?.id == attempt.id { engine.cancelLogin() } }
    }

    @ViewBuilder
    private var status: some View {
        switch attempt.phase {
        case .waiting:
            row(spinner: true,
                text: "Waiting for the browser to come back…",
                detail: attempt.throughServer
                    ? "The code is redeemed on the account server, which owns this "
                        + "account's sign-in. The browser half runs here."
                    : "Finish signing in, and this window closes on its own.")
        case .exchanging:
            row(spinner: true, text: "Redeeming the code…", detail: nil)
        case .failed(let message):
            row(spinner: false, text: "That did not work.", detail: message, tint: .red)
        case .succeeded(let name):
            row(spinner: false, text: "Signed in as \(name).", detail: nil, tint: .green)
        }
    }

    private func row(spinner: Bool, text: String, detail: String?,
                     tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: tint == .green
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(tint == .red ? tint : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or paste the code from the browser")
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                TextField("code#state, or the whole callback URL", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Use code") { submit() }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let pasteError = attempt.pasteError {
                Text(pasteError).font(.caption).foregroundStyle(.red)
            }
            Text("Some sign-ins show the code on the page instead of returning to ccmux. "
                 + "Paste it here and this finishes without the browser.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        let text = pasted.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        engine.submitLoginCode(text)
        pasted = ""
    }
}
