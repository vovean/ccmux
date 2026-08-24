import Foundation

/// One collapsible section on the Sessions screen. Managed and unmanaged sessions share
/// a group type so disclosure state has a single kind of key.
struct SessionGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let sessions: [SessionRecord]
    let unmanaged: [ClaudeSessionInfo]

    var count: Int { sessions.count + unmanaged.count }
    var isUnmanaged: Bool { id == SessionGrouping.unmanagedGroupID }
}

extension SessionGrouping {
    /// Groups whose account can no longer sign in. Every session in one is dead in the
    /// water, so the Sessions screen has to say so itself rather than leaving the news
    /// on the Accounts screen where the user may never look.
    static func expiredAccountIDs(in groups: [SessionGroup],
                                  accounts: [Account]) -> Set<String> {
        let expired = Set(accounts.filter { $0.health == .needsRelogin }.map(\.id))
        return Set(groups.map(\.id)).intersection(expired)
    }
}

enum SessionGrouping {
    /// Account ids are Anthropic account UUIDs, so a leading control character cannot
    /// collide with one.
    static let unmanagedGroupID = "\u{1}unmanaged"

    static func groups(accounts: [Account],
                       sessions: [SessionRecord],
                       unmanaged: [ClaudeSessionInfo]) -> [SessionGroup] {
        var byAccount: [String: [SessionRecord]] = [:]
        for session in sessions {
            byAccount[session.accountID, default: []].append(session)
        }

        var groups: [SessionGroup] = []
        for account in accounts {
            guard let owned = byAccount.removeValue(forKey: account.id) else { continue }
            groups.append(SessionGroup(id: account.id,
                                       title: account.displayName,
                                       subtitle: account.subscriptionType,
                                       sessions: owned,
                                       unmanaged: []))
        }

        // A session whose account was removed still holds a proxy port, so it gets a
        // group of its own rather than disappearing from the only screen that lists it.
        for accountID in byAccount.keys.sorted() {
            groups.append(SessionGroup(id: accountID,
                                       title: "Unknown account",
                                       subtitle: String(accountID.prefix(8)),
                                       sessions: byAccount[accountID] ?? [],
                                       unmanaged: []))
        }

        if !unmanaged.isEmpty {
            groups.append(SessionGroup(id: unmanagedGroupID,
                                       title: "Not managed by ccmux",
                                       subtitle: nil,
                                       sessions: [],
                                       unmanaged: unmanaged))
        }
        return groups
    }
}
