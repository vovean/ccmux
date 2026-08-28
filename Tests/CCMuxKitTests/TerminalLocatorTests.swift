import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Locating a session's terminal tab")
struct TerminalLocatorTests {
    private static let env =
        "PID TTY TIME CMD\n12345 s005 0:01.23 claude TERM_PROGRAM=iTerm.app "
        + "ITERM_SESSION_ID=w0t4p0:A1B2C3D4-1111-2222-3333-444455556666 SHELL=/bin/zsh"

    /// Only the UUID is kept. The `w0t4p0` in front records where the tab sat when the
    /// shell started and is wrong as soon as it is dragged anywhere — measured: a tab
    /// whose variable said window 0 tab 4 was living in a different window entirely,
    /// while its unique id still matched.
    @Test func theSessionIdIsTakenApartFromItsStaleIndices() {
        #expect(TerminalLocator.sessionID(inEnvironment: Self.env)
                == "A1B2C3D4-1111-2222-3333-444455556666")
        #expect(TerminalLocator.sessionID(inEnvironment: "SHELL=/bin/zsh TERM=xterm")
                == nil)
    }

    /// The tty is authoritative — it is the terminal the process is attached to — while
    /// the session id is merely inherited and can name an ancestor's tab. Both are kept:
    /// a `claude` with piped stdio has no tty at all, and one inside tmux has a tty iTerm
    /// does not own, so the inherited value is tried second rather than not at all.
    @Test func theTtyLeadsAndTheInheritedIdBacksItUp() {
        #expect(TerminalLocator.handles(environment: Self.env, tty: "ttys005")
                == [.tty("/dev/ttys005"),
                    .session("A1B2C3D4-1111-2222-3333-444455556666")])
        #expect(TerminalLocator.handles(environment: Self.env, tty: "??")
                == [.session("A1B2C3D4-1111-2222-3333-444455556666")])
        #expect(TerminalLocator.handles(environment: "SHELL=/bin/zsh", tty: "ttys005")
                == [.tty("/dev/ttys005")])
        #expect(TerminalLocator.handles(environment: "", tty: nil).isEmpty)
    }

    /// `ps -Eww` prints the command and its arguments before the environment, so an
    /// unanchored search would read the value straight out of somebody's argv.
    @Test func theVariableIsMatchedAsAWholeToken() {
        let argv = "12345 s005 0:01 some-tool --flag "
            + "ITERM_SESSION_ID=DEADBEEF-0000-1111-2222-333344445555"
        // Indistinguishable from the real thing once it is a bare token, but the
        // near-misses that an unanchored search would also accept are not.
        #expect(TerminalLocator.sessionID(
            inEnvironment: "FOO_ITERM_SESSION_ID=w0t0p0:DEADBEEF-0000-1111") == nil)
        #expect(TerminalLocator.sessionID(
            inEnvironment: "XITERM_SESSION_ID=w0t0p0:DEADBEEF-0000-1111") == nil)
        #expect(TerminalLocator.sessionID(inEnvironment: argv) != nil)
    }

    @Test func ttyNamesAreTurnedIntoDevicePaths() {
        #expect(TerminalLocator.device(forTTY: "ttys005") == "/dev/ttys005")
        #expect(TerminalLocator.device(forTTY: " ttys016 ") == "/dev/ttys016")
        #expect(TerminalLocator.device(forTTY: "/dev/ttys001") == "/dev/ttys001")
        #expect(TerminalLocator.device(forTTY: "??") == nil)
        #expect(TerminalLocator.device(forTTY: "") == nil)
        // Not a tty at all: `console` would match a real iTerm session for nobody.
        #expect(TerminalLocator.device(forTTY: "console") == nil)
    }

    /// Both handles land inside an AppleScript string literal. They are validated rather
    /// than escaped, so a value that could close the quote never reaches the script.
    @Test func aValueThatCouldBreakOutOfTheScriptIsRejected() {
        let hostile = "PATH=/bin ITERM_SESSION_ID=w0t0p0:\" & (do shell script \"id\") & \""
        #expect(TerminalLocator.sessionID(inEnvironment: hostile) == nil)
        #expect(TerminalLocator.device(forTTY: "ttys0\"; do shell script \"id") == nil)
        #expect(TerminalLocator.validUUID("../../etc/passwd") == nil)
        #expect(TerminalLocator.validUUID("short") == nil)
        #expect(TerminalLocator.validUUID(String(repeating: "A", count: 5000)) == nil)
    }

    /// The same thing through the real path — a live process whose environment says
    /// whatever it likes, read back with `ps`. Any process the user runs controls its
    /// own environment, so this is the boundary that matters.
    @Test func aHostileProcessEnvironmentCannotReachTheScript() throws {
        let hostiles = [
            #"w0t0p0:" & (do shell script "id") & ""#,
            #"w0t0p0:AAAAAAAA" & (do shell script "id") & "BB"#,
            "w0t0p0:../../../etc/passwd",
            "w0t0p0:" + String(repeating: "A", count: 5000),
        ]
        for hostile in hostiles {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["20"]
            var environment = ProcessInfo.processInfo.environment
            environment["ITERM_SESSION_ID"] = hostile
            process.environment = environment
            try process.run()
            defer { process.terminate() }

            let handle = TerminalOpener.handles(for: process.processIdentifier)
                .first { if case .session = $0 { return true } else { return false } }
            let value = handle?.value ?? ""
            #expect(!value.contains("\""))
            #expect(!value.contains("\\"))
            let script = handle.map(TerminalLocator.script(for:)) ?? ""
            #expect(!script.contains("do shell script"))
        }
    }

    /// Regression: it selected the wrong tab whenever the target window was not already
    /// frontmost. `repeat with t in tabs of w` binds "tab 3 of window 2", not a stable
    /// object, so selecting the window mid-loop renumbered `windows` and every reference
    /// after it pointed somewhere else. Discovery must finish before anything is
    /// selected, and the window — the only step that renumbers — must come last.
    @Test func nothingIsSelectedUntilTheSearchIsOver() throws {
        let script = TerminalLocator.script(for: .tty("/dev/ttys003"))
        let firstSelect = try #require(script.range(of: "select "))
        let loopsEnd = try #require(script.range(of: "if targetSession is missing value"))
        #expect(firstSelect.lowerBound > loopsEnd.lowerBound)

        let tab = try #require(script.range(of: "select targetTab"))
        let pane = try #require(script.range(of: "select targetSession"))
        let window = try #require(script.range(of: "select targetWindow"))
        #expect(tab.lowerBound < pane.lowerBound)
        #expect(pane.lowerBound < window.lowerBound)
    }

    @Test func theScriptComparesTheRightProperty() {
        let byID = TerminalLocator.script(for: .session("ABC12345-DEAD-BEEF"))
        #expect(byID.contains("(unique id of s) is \"ABC12345-DEAD-BEEF\""))
        #expect(byID.contains("sessions of t"))   // splits are walked, not just tabs
        #expect(byID.contains("return \"notfound\""))
        #expect(byID.contains("activate"))

        let byTTY = TerminalLocator.script(for: .tty("/dev/ttys005"))
        #expect(byTTY.contains("(tty of s) is \"/dev/ttys005\""))
    }

    @Test func everyFailureSaysSomething() {
        #expect(TerminalOpener.Outcome.opened.message == nil)
        for outcome: TerminalOpener.Outcome in [.notFound, .denied, .noHandle,
                                                .failed("boom")] {
            #expect(outcome.message?.isEmpty == false)
        }
    }
}
