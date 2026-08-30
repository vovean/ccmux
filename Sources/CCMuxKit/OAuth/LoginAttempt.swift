import CCMuxCore
import Foundation

/// A sign-in the user can see and act on.
///
/// Before this existed a login was a five-minute `await` inside `Engine`, invisible except
/// for a banner and a disabled button. Closing the browser left nothing to cancel and
/// nothing to retry — the only way out was to wait for the listener to time out.
public struct LoginAttempt: Identifiable, Equatable {
    public enum Phase: Equatable {
        /// The browser is open and the loopback listener is armed.
        case waiting
        /// A code arrived — from the browser or pasted — and is being redeemed.
        case exchanging
        case failed(String)
        case succeeded(String)
    }

    /// What is being signed in to. An existing account keeps its name in front of the
    /// user, so a relogin cannot be mistaken for adding a stranger.
    public enum Target: Equatable {
        case newAccount(label: String?)
        case existing(accountID: String, name: String)
    }

    public let id: UUID
    public var target: Target
    public var phase: Phase
    public var authorizeURL: String
    /// The code is redeemed on ccmuxd, because the account's refresh lineage lives there.
    /// The browser half still runs here — the server is headless.
    public var throughServer: Bool
    /// Set when the browser did not open — the URL went to the clipboard instead.
    public var launchNote: String?
    /// A rejected paste. Kept apart from `phase` so refusing a code cannot make an armed
    /// attempt look finished.
    public var pasteError: String?

    public init(id: UUID = UUID(), target: Target, phase: Phase = .waiting,
                authorizeURL: String, throughServer: Bool) {
        self.id = id
        self.target = target
        self.phase = phase
        self.authorizeURL = authorizeURL
        self.throughServer = throughServer
    }

    public var title: String {
        switch target {
        case .newAccount: return "Add a subscription"
        case .existing(_, let name): return "Sign in to \(name)"
        }
    }

    /// A code can still be pasted after a failure — a failed loopback is the single most
    /// likely reason to need the paste box at all.
    public var acceptsCode: Bool {
        switch phase {
        case .waiting, .failed: return true
        case .exchanging, .succeeded: return false
        }
    }

    public var isSucceeded: Bool {
        if case .succeeded = phase { return true }
        return false
    }

    public var isBusy: Bool {
        switch phase {
        case .waiting, .exchanging: return true
        case .failed, .succeeded: return false
        }
    }

    public var accountID: String? {
        switch target {
        case .newAccount: return nil
        case .existing(let id, _): return id
        }
    }
}

public enum LoginCode {
    /// What the browser hands back, in every spelling it uses.
    ///
    /// The authorize page shows `code#state`; a redirect delivers them as separate query
    /// items; and people paste the whole callback URL just as readily as the code itself.
    /// Splitting here rather than at each call site is what lets the paste box accept all
    /// three without the user having to know which one they have.
    /// The short numeric code the authorize page shows to confirm it is the same person.
    /// It belongs in that page, not in ccmux — but the wording ("enter this verification
    /// code where you first tried to sign in") reads like it belongs here.
    public static func looksLikeVerificationCode(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (4...10).contains(text.count) && text.allSatisfy(\.isNumber)
    }

    public static func parse(_ raw: String) -> (code: String, state: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("http"), let url = URLComponents(string: text) {
            let items = url.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value ?? ""
            guard !code.isEmpty else { return nil }
            // The state rides in the fragment as often as in the query.
            return (code, items.first { $0.name == "state" }?.value ?? url.fragment)
        }

        // No scheme. Peel the fragment first — `code#state` is what the authorize page
        // prints — then read whatever is left as parameters if it carries any.
        var fragment: String?
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[text.index(after: hash)...])
            text = String(text[..<hash])
        }
        let query = text.firstIndex(of: "?")
            .map { String(text[text.index(after: $0)...]) } ?? text
        if query.contains("=") {
            // Parsed as parameters rather than scanned for a "code=" prefix, so the pair
            // is found whatever order it was pasted in.
            let items = URLComponents(string: "http://ccmux/?" + query)?.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value ?? ""
            guard !code.isEmpty else { return nil }
            return (code, items.first { $0.name == "state" }?.value ?? fragment)
        }

        // A bare code. Anything still carrying URL punctuation is a paste we did not
        // understand, and guessing at it spends a round trip to be told so.
        guard !text.isEmpty, !text.contains("/"), !text.contains("&") else { return nil }
        return (text, fragment)
    }
}
