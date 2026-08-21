import Foundation

public enum KeychainError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}

/// Keychain access by shelling out to `/usr/bin/security`.
///
/// Deliberately not Security.framework: an in-process call binds the item's ACL to
/// *this* binary, which is re-signed on every rebuild, so macOS would prompt on the
/// first read after each build. `security` never changes, so creator == reader and
/// there is never a prompt. It is also how Claude Code itself reads and writes, which
/// is what lets us seed the items it looks for.
public enum Keychain {
    private static let tool = "/usr/bin/security"
    private static let notFound: Int32 = 44
    private static let timeout: TimeInterval = 5

    /// `security -i` reads stdin with a 4096-byte line buffer; a longer command is
    /// truncated mid-argument and silently fails to write.
    static let stdinLineLimit = 4096 - 64

    public static func accountName() -> String {
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty { return user }
        return NSUserName().isEmpty ? "claude-code-user" : NSUserName()
    }

    public static func read(service: String, account: String = accountName()) throws -> String? {
        let r = try run([tool, "find-generic-password", "-a", account, "-w", "-s", service])
        if r.code == 0 {
            var out = r.stdout
            if out.hasSuffix("\n") { out.removeLast() }
            return out
        }
        if r.code == notFound { return nil }
        throw KeychainError.failed("find-generic-password rc=\(r.code): \(r.stderr)")
    }

    public static func write(service: String, account: String = accountName(),
                            value: String) throws {
        let command = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) "
            + "-X \(Data(value.utf8).hexEncoded())\n"
        // Only the stdin path exists: the argv alternative would put the credential
        // where `ps` can read it, and a real Claude Code credential hex-encodes to
        // 1-2 KB against a 4032-byte budget, so refusing loudly beats degrading
        // silently.
        guard command.utf8.count <= stdinLineLimit else {
            throw KeychainError.failed(
                "credential is too large for `security -i` (\(command.utf8.count) bytes)")
        }
        let r = try run([tool, "-i"], stdin: command)
        if r.code != 0 {
            throw KeychainError.failed("add-generic-password rc=\(r.code): \(r.stderr)")
        }
    }

    public static func delete(service: String, account: String = accountName()) throws {
        let r = try run([tool, "delete-generic-password", "-a", account, "-s", service])
        if r.code == 0 || r.code == notFound { return }
        throw KeychainError.failed("delete-generic-password rc=\(r.code): \(r.stderr)")
    }

    /// `security -i` re-parses each line shell-style, so values must be quoted and
    /// embedded quotes escaped (service names contain spaces).
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    struct Result { let code: Int32; let stdout: String; let stderr: String }

    private static func run(_ argv: [String], stdin: String? = nil) throws -> Result {
        let p = Process()
        // Set before run(): a short-lived child can exit before the handler is
        // installed, and Process fires it immediately in that case.
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            p.standardInput = FileHandle.nullDevice
            try p.run()
        }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        // A polled wait costs ~28ms of pure sleep per call, and `security` is on the
        // proxy's request path; the termination handler answers as soon as the child
        // is reaped.
        if p.isRunning {
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            if p.isRunning, exited.wait(timeout: .now() + timeout) == .timedOut {
                p.terminate()
                throw KeychainError.failed("security timed out after \(Int(timeout))s")
            }
        }
        return Result(code: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}


extension Data {
    /// The encoding that decides which Keychain item is read and what value is written,
    /// so it exists once.
    func hexEncoded() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
