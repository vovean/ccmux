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
        Command(name: "server-check",
                usage: "server-check <address> [--username <u>] [--fingerprint <hex>]",
                run: serverCheck),
        Command(name: "hooks", usage: "hooks status | hooks push <dir> | hooks pull",
                run: hooks),
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

    // MARK: - hooks

    /// Publishes and inspects the hook set ccmuxd holds for every Mac.
    ///
    /// A separate verb from the app's own sync so publishing stays deliberate: the tick
    /// only ever pulls, and the one command that can change what three machines write to
    /// disk has to be typed.
    static func hooks(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let action = arguments.first ?? "status"
        let settings = JSONStore.load(Settings.self, from: Paths.settingsFile) ?? Settings()
        guard let connection = settings.server else {
            fail("no account server is configured")
        }
        let urls = connection.addresses.compactMap(URL.init(string:))
        guard !urls.isEmpty else { fail("the configured server address is not a URL") }
        guard let password = ProcessInfo.processInfo.environment["CCMUX_PASSWORD"]
            ?? ((try? ServerPasswordStore.read()) ?? nil) else {
            fail("no server password: set CCMUX_PASSWORD or connect the server in ccmux")
        }
        let client = ServerClient(baseURLs: urls, username: connection.username,
                                  password: password, fingerprint: connection.fingerprint,
                                  proxy: settings.upstreamProxy,
                                  proxyPassword: try? ProxyPasswordStore.read())

        let done = DispatchSemaphore(value: 0)
        var failure: String?
        Task {
            defer { done.signal() }
            do {
                switch action {
                case "status":
                    let remote = try await client.hooks()
                    let local = ManagedHooks.installedVersion()
                    let hooks = HookSync.classify(local: ManagedHooks.onDisk(),
                                                  server: remote.files,
                                                  baseline: HookBaseline.load())
                    print("server   \(remote.version.prefix(12))  \(remote.files.count) file(s)")
                    print("this Mac \(local.prefix(12))  \(ManagedHooks.root.path)")
                    let undecided = hooks.filter(\.needsDecision)
                    if undecided.isEmpty {
                        print(local == remote.version
                              ? "in sync" : "OUT OF SYNC — next tick will write")
                    } else {
                        print("HELD — \(undecided.count) file(s) changed on this Mac. "
                            + "Nothing is written until they are settled on the Hooks page, "
                            + "or with `ccmux hooks pull` to discard them.")
                    }
                    for hook in hooks {
                        let file = hook.local ?? hook.server
                        // "active" is the server's registration flag, not a local state:
                        // it says whether a Mac with registration turned on points Claude
                        // Code at this script.
                        let active = hook.server.map { $0.active ? "active" : "inactive" }
                            ?? "unpublished"
                        print("  \((file?.executable ?? false) ? "x" : "-") \(hook.path)  "
                            + "\(file?.content.utf8.count ?? 0) bytes  "
                            + "\(hook.state.rawValue)  \(active)")
                    }
                case "pull":
                    // Unconditional, unlike the app's tick: this is the escape hatch for a
                    // held sync, so it has to be able to throw local changes away.
                    let remote = try await client.hooks()
                    let result = try HookSync.install(remote.files, server: remote.files)
                    print("applied \(remote.version.prefix(12)): "
                        + "\(result.written.count) written, \(result.removed.count) removed")
                    for path in result.removed { print("  removed \(path)") }
                case "push":
                    guard arguments.count > 1 else { failure = "push needs a directory"; return }
                    var files = try collectHookFiles(from: arguments[1])
                    guard !files.isEmpty else { failure = "no files under \(arguments[1])"; return }
                    // Activation lives on the server and not on disk, so a directory push
                    // would re-register everything the user had turned off.
                    let current = (try? await client.hooks())?.files ?? []
                    let wasActive = Dictionary(current.map { ($0.path, $0.active) },
                                               uniquingKeysWith: { a, _ in a })
                    for i in files.indices {
                        files[i].active = wasActive[files[i].path] ?? true
                    }
                    let bundle = try await client.pushHooks(files)
                    print("published \(bundle.version.prefix(12)): \(bundle.files.count) file(s)")
                    for file in bundle.files { print("  \(file.executable ? "x" : "-") \(file.path)") }
                default:
                    failure = "unknown hooks action \(action)"
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        done.wait()
        if let failure { fail(failure) }
        exit(0)
    }

    /// Reads a directory into a bundle, keeping the executable bit — a hook that arrives
    /// non-executable never runs, and nothing about that failure says why.
    private static func collectHookFiles(from directory: String) throws -> [HookFile] {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var files: [HookFile] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if let why = ManagedHooks.validate(relative) {
                fail("\(relative): \(why)")
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            let mode = ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
                as? Int) ?? 0
            files.append(HookFile(path: relative, content: content,
                                  executable: (mode & 0o100) != 0))
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - server-check

    /// Reproduces first-connect against a ccmuxd and narrates every step.
    ///
    /// Runs the real `ServerClient`, deliberately. A standalone reimplementation of the
    /// pinning logic was written to chase a Mac that could not connect, and it succeeded
    /// on the machine where the app failed — which proved only that the reimplementation
    /// was not the app. Anything that is going to answer this question has to be the
    /// shipped class, on the shipped binary, in the shipped bundle.
    static func serverCheck(_ arguments: [String]) -> Never {
        var address: String?
        var username = "ccmux"
        var fingerprint: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--username":
                index += 1
                guard index < arguments.count else { fail("--username needs a value") }
                username = arguments[index]
            case "--fingerprint":
                index += 1
                guard index < arguments.count else { fail("--fingerprint needs a value") }
                fingerprint = arguments[index].lowercased()
            default:
                guard address == nil else { fail("unexpected argument \(arguments[index])") }
                address = arguments[index]
            }
            index += 1
        }
        guard let address else { fail("server-check needs an address") }
        let urls = CCMuxKit.Engine.serverAddresses(address)
        guard let url = urls.first else { fail("\(address) is not a URL") }
        // The trace runs on a URLSession queue while the narration runs here, and a
        // buffered stdout interleaves the two into nonsense — the first run printed every
        // trace line above the heading it belonged under.
        setvbuf(stdout, nil, _IONBF, 0)
        // Never from argv: a password there is visible in `ps` to every user on the
        // machine and lands in shell history.
        let password = ProcessInfo.processInfo.environment["CCMUX_PASSWORD"]
            ?? (try? ServerPasswordStore.read()) ?? nil

        print("address     \(address)")
        print("normalized  \(urls.map(\.absoluteString).joined(separator: ", "))")
        print("username    \(username)")
        print("password    \(password == nil ? "none — will stop after the probe" : "supplied")")
        print("system proxy for this URL: \(systemProxyDescription(for: url))")
        print("")

        let trace: ServerTrace = { line in
            print("  \(line)")
            Log.info("server-check: \(line)")
        }

        let done = DispatchSemaphore(value: 0)
        var failure: String?
        Task {
            defer { done.signal() }
            print("--- probe (accepts any certificate, sends no credentials) ---")
            let observed: String
            let answered: URL
            do {
                let found = try await ServerClient.probe(
                    baseURLs: urls, proxy: nil, proxyPassword: nil, trace: trace)
                observed = found.fingerprint
                answered = found.url
            } catch {
                await tlsMatrix(url)
                failure = "probe failed: \(ServerDiagnostics.describe(error))"
                return
            }
            print("  fingerprint \(ServerFingerprint.display(observed))")
            if urls.count > 1 { print("  answered at \(answered.absoluteString)") }
            print("")

            guard let password else { return }
            let pin = fingerprint ?? observed
            if fingerprint == nil {
                print("--- authenticated request (pinning the fingerprint just probed) ---")
            } else {
                print("--- authenticated request (pinning \(pin)) ---")
            }
            let client = ServerClient(baseURLs: urls, username: username,
                                      password: password, fingerprint: pin, proxy: nil,
                                      proxyPassword: nil, trace: trace)
            do {
                let health = try await client.health()
                print("  health ok: apiVersion=\(health.apiVersion)")
                let accounts = try await client.accounts()
                print("  accounts: \(accounts.count)")
                for account in accounts {
                    print("    \(account.id)  \(account.label)  \(account.health)")
                }
            } catch {
                await tlsMatrix(url)
                failure = "authenticated request failed: "
                    + ServerDiagnostics.describe(error)
            }
        }
        done.wait()
        if let failure {
            print("")
            fail(failure)
        }
        print("")
        print("OK")
        exit(0)
    }

    /// Which TLS versions this machine can actually complete a handshake with.
    ///
    /// Trust is out of the picture here — every certificate is accepted — so a failure at
    /// one ceiling and not another is the protocol itself, not the pin, the certificate or
    /// the network. That distinction is the one the app could never make: every cause
    /// arrived as the same sentence about an SSL error.
    private static func tlsMatrix(_ url: URL) async {
        print("")
        print("--- TLS version matrix (accepts any certificate, no credentials) ---")
        let ceilings: [(String, tls_protocol_version_t)] = [
            ("max TLS 1.2", .TLSv12),
            ("max TLS 1.3", .TLSv13),
        ]
        for (label, version) in ceilings {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.tlsMaximumSupportedProtocolVersion = version
            let delegate = AcceptAnyTrust()
            let session = URLSession(configuration: config, delegate: delegate,
                                     delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url.appendingPathComponent("v1/health"))
            request.httpMethod = "GET"
            do {
                let (_, response) = try await session.data(for: request)
                print("  \(label): HTTP "
                    + "\((response as? HTTPURLResponse)?.statusCode.description ?? "?")")
            } catch {
                print("  \(label): \(ServerDiagnostics.describe(error))")
            }
        }
    }

    /// What the system would route this URL through if nothing overrides it — which is
    /// exactly what a URLSession with no `connectionProxyDictionary` does.
    private static func systemProxyDescription(for url: URL) -> String {
        guard let settings = CFNetworkCopySystemProxySettings()?
            .takeRetainedValue() as? [AnyHashable: Any] else { return "unreadable" }
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL,
                                                 settings as CFDictionary)
            .takeRetainedValue() as? [[AnyHashable: Any]] ?? []
        let described = proxies.compactMap { proxy -> String? in
            guard let type = proxy[kCFProxyTypeKey as String] as? String else { return nil }
            if type == kCFProxyTypeNone as String { return "direct" }
            let host = proxy[kCFProxyHostNameKey as String] as? String ?? "?"
            let port = proxy[kCFProxyPortNumberKey as String] as? Int ?? 0
            return "\(type) \(host):\(port)"
        }
        return described.isEmpty ? "direct" : described.joined(separator: ", ")
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

/// Accepts every certificate. Only ever used by `server-check`'s TLS matrix, which is
/// asking what the protocol does and has no opinion about who it is talking to.
private final class AcceptAnyTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
