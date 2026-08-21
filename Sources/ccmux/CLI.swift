import CCMuxKit
import Darwin
import Foundation

enum CLI {
    static let subcommands: Set<String> = ["run", "status", "assign", "end", "import",
                                          "shell-init", "help", "--help", "-h", "--version"]

    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        return subcommands.contains(arguments[1])
    }

    static func main(_ arguments: [String]) -> Never {
        switch arguments[1] {
        case "run": run(Array(arguments.dropFirst(2)))
        case "status": status()
        case "assign": assign(Array(arguments.dropFirst(2)))
        case "end": end(Array(arguments.dropFirst(2)))
        case "import": importLogin()
        case "shell-init": shellInit()
        case "--version": print("ccmux 1.0"); exit(0)
        default: usage(); exit(0)
        }
    }

    static func usage() {
        print("""
        ccmux — run Claude Code sessions on separate subscriptions

        Usage:
          ccmux run --policy <name> [--account <id>] [-- <claude args>…]
          ccmux status
          ccmux assign <session-id> <account-id>
          ccmux import
          ccmux end <session-id>
          ccmux shell-init

        With no subcommand, ccmux opens its window.
        """)
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
                claudeArgs = Array(arguments[(index + 1)...])
                index = arguments.count
                continue
            default:
                // Anything unrecognised is meant for claude, so a bare
                // `cc-opus --resume` keeps working without needing `--`.
                claudeArgs.append(arguments[index])
            }
            index += 1
        }
        if accountID != nil {
            fail("--account is not implemented for run yet; assign after launch instead")
        }

        do {
            try ControlClient.ensureRunning()
        } catch {
            fail(error.localizedDescription)
        }

        let cwd = FileManager.default.currentDirectoryPath
        let response: ControlResponse
        do {
            response = try ControlClient.send(
                .newSession(policy: policy, cwd: cwd, pid: getpid()))
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

        setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", info.namespaceDir, 1)
        setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:\(info.port)", 1)
        setenv("_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL", "1", 1)
        setenv("CCMUX_SESSION_ID", info.sessionID, 1)

        guard let binary = claudeBinary() else {
            fail("could not find the claude executable on PATH")
        }
        // exec, not spawn: the pid ccmux was told about has to end up being claude's,
        // because that is the key it matches against ~/.claude/sessions/<pid>.json.
        let argv = [binary] + claudeArgs
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
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
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if resolved == mine { continue }
            return candidate
        }
        return nil
    }

    // MARK: - status

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
            var line = "\(account.label)\(flag)"
            if let age = account.usageAge, age < 86400 {
                line += "  (\(Int(age))s ago)"
            }
            print(line)
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
                print("    \(session.sessionID.prefix(8))  pid \(session.pid)  "
                      + "\(session.accountLabel)  policy \(session.policyName)")
            }
        }
        exit(0)
    }

    static func assign(_ arguments: [String]) -> Never {
        guard arguments.count == 2 else { fail("usage: ccmux assign <session-id> <account-id>") }
        guard let response = try? ControlClient.send(
            .assign(sessionID: arguments[0], accountID: arguments[1])) else {
            fail("ccmux is not running")
        }
        if case .failure(let message) = response { fail(message) }
        print("assigned")
        exit(0)
    }

    static func end(_ arguments: [String]) -> Never {
        guard arguments.count == 1 else { fail("usage: ccmux end <session-id>") }
        _ = try? ControlClient.send(.endSession(sessionID: arguments[0]))
        print("ended")
        exit(0)
    }

    static func importLogin() -> Never {
        do {
            try ControlClient.ensureRunning()
        } catch {
            fail(error.localizedDescription)
        }
        guard let response = try? ControlClient.send(.importGlobalLogin) else {
            fail("ccmux is not running")
        }
        if case .failure(let message) = response { fail(message) }
        print("imported the current Claude Code login")
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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ccmux: \(message)\n".utf8))
        exit(1)
    }
}
