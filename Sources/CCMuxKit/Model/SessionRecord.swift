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
    /// Dollars this session has spent on API-key accounts. Subscription requests are
    /// prepaid, so they never add to it — a number here always means real money.
    public var spendUSD: Double

    public init(id: String, pid: Int32, port: UInt16, accountID: String,
                policyName: String, cwd: String, startedAt: Date = Date(),
                autoSwitchOverride: Bool? = nil, spendUSD: Double = 0) {
        self.id = id
        self.pid = pid
        self.port = port
        self.accountID = accountID
        self.policyName = policyName
        self.cwd = cwd
        self.startedAt = startedAt
        self.autoSwitchOverride = autoSwitchOverride
        self.spendUSD = spendUSD
    }

    /// Hand-written so a sessions file written before `spendUSD` existed still decodes;
    /// synthesized decoding would fail the whole table and drop every live session.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pid = try c.decode(Int32.self, forKey: .pid)
        port = try c.decode(UInt16.self, forKey: .port)
        accountID = try c.decode(String.self, forKey: .accountID)
        policyName = try c.decode(String.self, forKey: .policyName)
        cwd = try c.decode(String.self, forKey: .cwd)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        autoSwitchOverride = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchOverride)
        spendUSD = try c.decodeIfPresent(Double.self, forKey: .spendUSD) ?? 0
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
    /// When Claude Code last touched this session — its best available stand-in for the
    /// time of the last message.
    public var updatedAt: Date?

    public var id: Int32 { pid }
}
