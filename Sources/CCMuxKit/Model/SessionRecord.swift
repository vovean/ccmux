import Foundation

/// A session ccmux launched. `pid` is the claude process itself: the shim execs
/// claude, so the shim's pid becomes claude's pid, which is also the key in
/// ~/.claude/sessions/<pid>.json.
public struct SessionRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var pid: Int32
    public var port: UInt16
    public var accountID: String
    public var policyName: String
    public var cwd: String
    public var startedAt: Date
    /// nil follows the global setting. Snapshotting the setting at birth instead would
    /// permanently opt out every session started while auto-switch was off, which is
    /// indistinguishable from the feature being broken.
    public var autoSwitchOverride: Bool?
    /// Set when this session's namespace owns the account's credential lineage,
    /// i.e. Claude Code is allowed to refresh it and we adopt the result.
    public var ownsLineage: Bool

    public init(id: String, pid: Int32, port: UInt16, accountID: String,
                policyName: String, cwd: String, startedAt: Date = Date(),
                autoSwitchOverride: Bool? = nil, ownsLineage: Bool = false) {
        self.id = id
        self.pid = pid
        self.port = port
        self.accountID = accountID
        self.policyName = policyName
        self.cwd = cwd
        self.startedAt = startedAt
        self.autoSwitchOverride = autoSwitchOverride
        self.ownsLineage = ownsLineage
    }

    public var namespaceDir: URL { Paths.namespace(id) }

    public func autoSwitchEnabled(default globalDefault: Bool) -> Bool {
        autoSwitchOverride ?? globalDefault
    }
}

/// A live Claude Code session as Claude Code itself records it.
public struct ClaudeSessionInfo: Equatable, Identifiable {
    public var pid: Int32
    public var sessionID: String
    public var cwd: String
    public var name: String?
    public var status: String?
    public var version: String?
    public var kind: String?
    public var entrypoint: String?
    public var startedAt: Date?

    public var id: Int32 { pid }
}
