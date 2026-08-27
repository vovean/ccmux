import CCMuxCore
import Foundation

/// Finding the iTerm tab a session is running in.
///
/// Both handles come from the process itself at the moment you ask, so nothing has to be
/// captured at launch: a session started before this existed is as reachable as a new
/// one, and a session ccmux did not launch is reachable too.
public enum TerminalLocator {
    public enum Handle: Equatable {
        /// iTerm's own `unique id`, read from the process's `ITERM_SESSION_ID`.
        ///
        /// Preferred over the tty for two reasons: it survives the tab being dragged to
        /// another window, and a `claude` whose stdio is piped has no controlling
        /// terminal at all yet still carries the variable it inherited.
        case session(String)
        case tty(String)

        /// The iTerm property to compare against.
        var property: String {
            switch self {
            case .session: return "unique id"
            case .tty: return "tty"
            }
        }

        var value: String {
            switch self {
            case .session(let id): return id
            case .tty(let path): return path
            }
        }
    }

    /// Handles to try, best first.
    ///
    /// The tty leads because it is authoritative: it is the terminal the process is
    /// actually attached to. `ITERM_SESSION_ID` is merely inherited, so a `claude` whose
    /// ancestor exported another tab's value names that tab instead. It is still tried,
    /// second, because two real cases have no usable tty: a `claude` with piped stdio has
    /// none at all, and one inside tmux has a tty iTerm does not own.
    public static func handles(environment: String, tty: String?) -> [Handle] {
        var found: [Handle] = []
        if let device = tty.flatMap(device(forTTY:)) { found.append(.tty(device)) }
        if let id = sessionID(inEnvironment: environment) { found.append(.session(id)) }
        return found
    }

    /// `ITERM_SESSION_ID` looks like `w0t4p0:UUID`. Only the UUID is kept: the window and
    /// tab indices in front of it are a snapshot of where the tab sat when the shell
    /// started, and go stale the moment it is moved.
    /// Scanned token by token rather than by substring: `ps -Eww` prints the command
    /// and its arguments before the environment, and an unanchored search would just as
    /// happily read the value out of somebody's argv — or out of `FOO_ITERM_SESSION_ID=`.
    static func sessionID(inEnvironment environment: String) -> String? {
        for token in environment.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("ITERM_SESSION_ID=") else { continue }
            let value = token.dropFirst("ITERM_SESSION_ID=".count)
            let uuid = value.contains(":")
                ? value.split(separator: ":").last.map(String.init)
                : String(value)
            return uuid.flatMap(validUUID)
        }
        return nil
    }

    /// Validated rather than escaped. Both handles end up inside an AppleScript string
    /// literal, and a value that cannot contain a quote or a backslash cannot break out
    /// of one.
    static func validUUID(_ text: String) -> String? {
        // A real one is 36 characters. The upper bound is here so the rejection of an
        // absurd value is a decision rather than a side effect of how much of the
        // environment `ps` chooses to print.
        let ok = (8...64).contains(text.count) && text.allSatisfy {
            $0.isHexDigit || $0 == "-"
        }
        return ok ? text : nil
    }

    /// `ps -o tty=` prints `ttys005`, or `??` when the process has no controlling
    /// terminal. iTerm reports the full device path.
    static func device(forTTY raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "??", name != "?" else { return nil }
        let bare = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
        guard bare.allSatisfy({ $0.isLetter || $0.isNumber }), bare.hasPrefix("tty") else {
            return nil
        }
        return "/dev/" + bare
    }

    /// Walks panes, not just tabs, so a session in a split is found and its pane is the
    /// one left selected.
    ///
    /// Two rules here are load-bearing, both learned by watching it pick the wrong tab:
    ///
    /// 1. Nothing is selected while the loops are running. `repeat with t in tabs of w`
    ///    binds a *positional* reference — "tab 3 of window 2" — not a stable object, so
    ///    any mutation mid-iteration re-points every remaining reference.
    /// 2. The window is selected last. Raising a window renumbers `windows`, which
    ///    invalidates the tab and pane references; done last there is nothing left to
    ///    invalidate. Selecting only the pane is not enough — it does not change which
    ///    tab is current.
    public static func script(for handle: Handle) -> String {
        """
        tell application "iTerm2"
          set targetWindow to missing value
          set targetTab to missing value
          set targetSession to missing value
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (\(handle.property) of s) is "\(handle.value)" then
                  set targetWindow to w
                  set targetTab to t
                  set targetSession to s
                end if
              end repeat
            end repeat
          end repeat
          if targetSession is missing value then return "notfound"
          select targetTab
          select targetSession
          select targetWindow
          activate
          return "opened"
        end tell
        """
    }
}
