import CCMuxKit
import Darwin
import Foundation

enum CLI {
    /// One table, so a command cannot exist in the dispatch switch but be missing from
    /// the recognised set — which would silently open the GUI instead of running it.
    struct Command {
        let name: String
        let usage: String
        let run: ([String]) -> Never
    }

    static let commands: [Command] = [
        Command(name: "run",
                usage: "run --policy <name> [--account <id>] [-- <claude args>…]",
                run: run),
        Command(name: "status", usage: "status", run: { _ in status() }),
        Command(name: "assign", usage: "assign <session-id> <account-id>", run: assign),
        Command(name: "end", usage: "end <session-id>", run: end),
        Command(name: "import", usage: "import", run: { _ in importLogin() }),
        Command(name: "shell-init", usage: "shell-init", run: { _ in shellInit() }),
        Command(name: "install-agent", usage: "install-agent",
                run: { _ in installAgent() }),
        Command(name: "uninstall-agent", usage: "uninstall-agent",
                run: { _ in uninstallAgent() }),
    ]

    /// Read from the bundle rather than hardcoded, so it cannot drift from what was
    /// actually shipped — a constant here was still reporting 1.0 out of a 1.1 build.
    ///
    /// Homebrew installs the CLI as a symlink into its bin directory, and through a
    /// symlink `Bundle.main` is not the app bundle at all, so the executable's own path
    /// is resolved and walked back to Contents/Info.plist.
    static var version: String {
        if let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return bundled
        }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath
                             ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = executable
            .deletingLastPathComponent()   // …/Contents/MacOS
            .deletingLastPathComponent()   // …/Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String
        else { return "unknown" }
        return version
    }

    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return commands.contains { $0.name == first }
            || ["help", "--help", "-h", "--version"].contains(first)
    }

    static func main(_ arguments: [String]) -> Never {
        let name = arguments[1]
        if name == "--version" { print("ccmux \(version)"); exit(0) }
        guard let command = commands.first(where: { $0.name == name }) else {
            usage()
            exit(name == "help" || name == "--help" || name == "-h" ? 0 : 1)
        }
        command.run(Array(arguments.dropFirst(2)))
    }

    static func usage() {
        print("ccmux — run Claude Code sessions on separate subscriptions\n")
        print("Usage:")
        for command in commands { print("  ccmux \(command.usage)") }
        print("\nWith no subcommand, ccmux opens its window.")
    }

    // MARK: - run

    static func run(_ arguments: [String]) -> Never {
        var policy = "any"
        var accountID: String?
        var claudeArgs: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            // Long forms only: claude owns -p (print) and short flags generally, and a
            // shim that swallowed them would break `cc-opus -p "…"`.
            case "--policy":
                index += 1
                guard index < arguments.count else { fail("--policy needs a value") }
                policy = arguments[index]
            case "--account":
                index += 1
                guard index < arguments.count else { fail("--account needs a value") }
                accountID = arguments[index]
            case "--":
                claudeArgs += arguments[(index + 1)...]
                index = arguments.count
                continue
            default:
                // Anything unrecognised is meant for claude, so a bare
                // `cc-opus --resume` keeps working without needing `--`.
                claudeArgs.append(arguments[index])
            }
            index += 1
        }

        do {
            try ControlClient.ensureRunning()
        } catch {
            fail(error.localizedDescription)
        }

        let response: ControlResponse
        do {
            response = try ControlClient.send(.newSession(
                policy: policy, cwd: FileManager.default.currentDirectoryPath,
                pid: getpid(), accountID: accountID))
        } catch {
            fail(error.localizedDescription)
        }
        guard case .session(let info) = response else {
            if case .failure(let message) = response { fail(message) }
            fail("unexpected response from ccmux")
        }

        FileHandle.standardError.write(Data(
            "ccmux: \(info.accountLabel) · policy \(info.policyName) · port \(info.port)\n"
                .utf8))
        if let warning = info.warning {
            FileHandle.standardError.write(Data("ccmux: warning — \(warning)\n".utf8))
        }

        setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", info.namespaceDir, 1)
        setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(info.port)", 1)
        setenv("_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL", "1", 1)
        setenv("CCMUX_SESSION_ID", info.sessionID, 1)

        guard let binary = claudeBinary() else {
            fail("could not find the claude executable on PATH")
        }
        // exec, not spawn: the pid ccmux was told about has to end up being claude's,
        // because that is the key it matches against ~/.claude/sessions/<pid>.json.
        var cArgs: [UnsafeMutablePointer<CChar>?] = ([binary] + claudeArgs).map { strdup($0) }
        cArgs.append(nil)
        execv(binary, &cArgs)
        fail("exec \(binary) failed (errno \(errno))")
    }

    /// Resolves `claude` on PATH, skipping ccmux itself so a symlink named `claude`
    /// pointing here cannot make the shim recurse.
    static func claudeBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["CCMUX_CLAUDE_BIN"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let mine = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/claude"
            guard FileManager.default.isExecutableFile(atPath: candidate),
                  URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path != mine
            else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - Other commands

    static func status() -> Never {
        guard let response = try? ControlClient.send(.status),
              case .status(let status) = response else {
            fail("ccmux is not running")
        }
        if status.accounts.isEmpty {
            print("No accounts. Open ccmux and add one.")
        }
        for account in status.accounts {
            let flag = account.health == "needsRelogin" ? " [needs re-login]" : ""
            let age = account.usageAge.map { "  (\(Int($0))s ago)" } ?? ""
            print("\(account.label)\(flag)\(age)")
            for window in account.windows {
                let reset = window.resetsAt.map { " resets in \(Format.countdown(to: $0))" } ?? ""
                let name = window.label.padding(toLength: max(22, window.label.count),
                                                withPad: " ", startingAt: 0)
                print("    \(name) " + String(format: "%5.0f%% used", window.percent) + reset)
            }
        }
        if !status.sessions.isEmpty {
            print("\nSessions:")
            for session in status.sessions {
                // Printed in full: `ccmux assign` and `ccmux end` take the whole id.
                print("    \(session.sessionID)  pid \(session.pid)  "
                      + "\(session.accountLabel)  policy \(session.policyName)")
            }
        }
        exit(0)
    }

    static func assign(_ arguments: [String]) -> Never {
        guard arguments.count == 2 else { fail("usage: ccmux assign <session-id> <account-id>") }
        send(.assign(sessionID: arguments[0], accountID: arguments[1]), success: "assigned")
    }

    static func end(_ arguments: [String]) -> Never {
        guard arguments.count == 1 else { fail("usage: ccmux end <session-id>") }
        send(.endSession(sessionID: arguments[0]), success: "ended")
    }

    static func importLogin() -> Never {
        do {
            try ControlClient.ensureRunning()
        } catch {
            fail(error.localizedDescription)
        }
        send(.importGlobalLogin, success: "imported the current Claude Code login")
    }

    static func send(_ request: ControlRequest, success: String) -> Never {
        guard let response = try? ControlClient.send(request) else {
            fail("ccmux is not running")
        }
        if case .failure(let message) = response { fail(message) }
        print(success)
        exit(0)
    }

    static func shellInit() -> Never {
        print("""
        # ccmux shell aliases — add to ~/.zshrc
        cc-opus()  { ccmux run --policy opus  "$@" }
        cc-fable() { ccmux run --policy fable "$@" }
        cc-any()   { ccmux run --policy any   "$@" }
        """)
        exit(0)
    }

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.vovean.ccmux.plist")
    }

    /// Launches through `open`, never the binary: Launch Services registration is what
    /// makes notification authorization possible at all. `-g` leaves the window closed.
    /// KeepAlive is deliberately absent because `open` exits immediately.
    private static let agentPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>io.vovean.ccmux</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/bin/open</string>
            <string>-g</string>
            <string>/Applications/ccmux.app</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>ProcessType</key>
        <string>Interactive</string>
    </dict>
    </plist>
    """

    static func installAgent() -> Never {
        let url = agentPlistURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try agentPlist.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write \(url.path): \(error.localizedDescription)")
        }
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/io.vovean.ccmux"])
        if run("/bin/launchctl", ["bootstrap", "gui/\(uid)", url.path]) != 0 {
            fail("wrote \(url.path) but launchctl bootstrap failed")
        }
        print("ccmux will start at login")
        exit(0)
    }

    static func uninstallAgent() -> Never {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/io.vovean.ccmux"])
        try? FileManager.default.removeItem(at: agentPlistURL)
        print("login item removed")
        exit(0)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ccmux: \(message)\n".utf8))
        exit(1)
    }
}
