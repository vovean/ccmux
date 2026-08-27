import CCMuxCore
import Foundation

/// Ties a directory to the account a session started there should launch on.
///
/// Claude.ai connectors — the Slack, Drive and Jira integrations an admin approves —
/// are scoped to an Anthropic *organization*, and Claude Code fetches the list once at
/// startup using the token it finds in its namespace. So the launch account decides
/// which connectors a session has for its whole life; reassigning it later cannot add
/// them, and rotating it away cannot take them away. Binding a project directory to an
/// account is what makes `cc-opus` in that project start in the right organization
/// without anyone having to remember a flag.
public struct DirectoryBinding: Codable, Equatable, Identifiable {
    public var path: String
    public var accountID: String

    public var id: String { path }

    public init(path: String, accountID: String) {
        self.path = path
        self.accountID = accountID
    }
}

public enum DirectoryBindings {
    /// The binding governing `cwd`, longest path first so a nested project overrides the
    /// rule its parent set.
    public static func match(_ cwd: String,
                             in bindings: [DirectoryBinding]) -> DirectoryBinding? {
        let target = components(cwd)
        return bindings
            .map { ($0, components($0.path)) }
            .filter { covers($0.1, target) }
            .max { $0.1.count < $1.1.count }?
            .0
    }

    /// Compared component by component: a rule for `/src/app` must not capture
    /// `/src/app-legacy`, which prefix matching on the raw string would.
    static func covers(_ parent: [String], _ child: [String]) -> Bool {
        guard !parent.isEmpty, parent.count <= child.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    static func components(_ path: String) -> [String] {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = "/" + expanded
        }
        return (expanded as NSString).standardizingPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Accounts a session bound to `binding` may launch on: the whole organization, not
    /// just the one account, so a second seat in the same organization is usable and
    /// still carries the same connectors. An account with no organization recorded
    /// stands alone — an unknown organization is not evidence of a shared one.
    public static func bindable(_ accounts: [Account]) -> [Account] {
        accounts.filter { $0.kind == .subscription }
    }

    public static func launchPool(for binding: DirectoryBinding,
                                  among accounts: [Account]) -> [Account] {
        guard let bound = accounts.first(where: { $0.id == binding.accountID })
        else { return [] }
        guard let org = bound.organizationUUID else { return [bound] }
        return accounts.filter { $0.organizationUUID == org }
    }
}

extension DirectoryBindings {
    /// What a binding says about where a session in `cwd` should launch.
    public enum Launch: Equatable {
        /// No rule covers this directory; rank accounts the usual way.
        case unbound
        case use(AccountRanking)
        /// Every account in the bound organization is spent. The caller launches
        /// elsewhere; the name is for saying so out loud, since the session will not
        /// have the connectors that organization approved.
        case organizationSpent(String)
    }

    /// `accounts` is the *bindable* set, not the auto-assignable one. A binding is an
    /// explicit statement, so it reaches an account held out of rotation — "never pick
    /// this on your own, except here" is the point of pairing the two. It does not reach
    /// an API key: spending money stays a per-session act.
    public static func launch(cwd: String?, settings: Settings, accounts: [Account],
                              usage: [String: UsageSnapshot], policy: Policy,
                              excluding: Set<String> = [],
                              applyingLaunchFloors: Bool = false) -> Launch {
        guard let cwd, let binding = match(cwd, in: settings.directoryBindings) else {
            return .unbound
        }
        let pool = launchPool(for: binding, among: accounts)
        // Scraps inside the bound organization beat a fresh account outside it: the
        // session keeps the connectors that organization approved, and it can rotate out
        // for quota the moment it needs to without losing them again.
        if let choice = PolicyEngine.pick(accounts: pool, usage: usage, policy: policy,
                                          excluding: excluding,
                                          applyingLaunchFloors: applyingLaunchFloors)
            // `.last` is the most headroom: ranking is least-remaining-first, and this
            // is the same scraps fallback the unbound path uses. Taking `.first` here
            // would start the session on the seat that gets refused soonest.
            ?? PolicyEngine.rank(accounts: pool, usage: usage, policy: policy,
                                 excluding: excluding).last {
            return .use(choice)
        }
        let named = accounts.first { $0.id == binding.accountID }
        return .organizationSpent(named?.organizationName ?? named?.displayName
                                  ?? "its bound account")
    }
}
