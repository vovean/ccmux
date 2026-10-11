import CCMuxCore
import Foundation

public enum ControlRequest: Codable, Equatable {
    case ping
    /// The shim asks for a session. `pid` is the shim's own pid, which becomes the
    /// claude pid because the shim execs claude — that is how a session is later
    /// matched to ~/.claude/sessions/<pid>.json.
    /// `group` is a name from `--group`; absent from an older shim's request, which
    /// decodes as nil.
    case newSession(policy: String, cwd: String, pid: Int32, accountID: String?,
                    group: String? = nil)
    case endSession(sessionID: String)
    case assign(sessionID: String, accountID: String)
    case status
    /// Adopts the credential Claude Code is already logged in with.
    case importGlobalLogin
}

public struct ControlSessionInfo: Codable, Equatable {
    public var sessionID: String
    public var namespaceDir: String
    public var port: UInt16
    public var accountID: String
    public var accountLabel: String
    public var policyName: String
    public var pid: Int32
    /// Set when the chosen account did not clear the policy's launch floor, so the shim
    /// can say the session is starting on scraps. Optional so an older app that does not
    /// send it still decodes.
    public var warning: String?
    /// The group the session was launched in. The shim checks it came back: an older app
    /// ignores `--group` without saying so and would launch outside the group.
    public var groupName: String?

    public init(sessionID: String, namespaceDir: String, port: UInt16, accountID: String,
                accountLabel: String, policyName: String, pid: Int32,
                warning: String? = nil, groupName: String? = nil) {
        self.sessionID = sessionID
        self.namespaceDir = namespaceDir
        self.port = port
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.policyName = policyName
        self.pid = pid
        self.warning = warning
        self.groupName = groupName
    }
}

public struct ControlAccountInfo: Codable, Equatable {
    public var id: String
    public var label: String
    public var email: String?
    public var health: String
    public var windows: [UsageWindow]
    public var usageAge: TimeInterval?
    public var groupName: String?
    public var inRotation: Bool?

    public init(id: String, label: String, email: String?, health: String,
                windows: [UsageWindow], usageAge: TimeInterval?, groupName: String? = nil,
                inRotation: Bool? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.health = health
        self.windows = windows
        self.usageAge = usageAge
        self.groupName = groupName
        self.inRotation = inRotation
    }
}

public struct ControlStatus: Codable, Equatable {
    public var accounts: [ControlAccountInfo]
    public var sessions: [ControlSessionInfo]
    /// This Mac's group; nil means it chooses only accounts in no group.
    public var restrictedGroupName: String?
    /// Limited to a group that no longer exists, so nothing can be chosen.
    public var restrictedGroupMissing: Bool?

    public init(accounts: [ControlAccountInfo], sessions: [ControlSessionInfo],
                restrictedGroupName: String? = nil, restrictedGroupMissing: Bool? = nil) {
        self.accounts = accounts
        self.sessions = sessions
        self.restrictedGroupName = restrictedGroupName
        self.restrictedGroupMissing = restrictedGroupMissing
    }
}

public enum ControlResponse: Codable, Equatable {
    case ok
    case session(ControlSessionInfo)
    case status(ControlStatus)
    case failure(String)
}
