import CCMuxCore
import Foundation

/// One collapsible section on the Sessions screen. Managed and unmanaged sessions share
/// a group type so disclosure state has a single kind of key.
struct SessionGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let sessions: [SessionRecord]
    let unmanaged: [ClaudeSessionInfo]
    /// Sessions for this account running on other Macs. Read-only, and counted apart from
    /// `count` — every existing caller of that means "how many are running here".
    var foreign: [ForeignSession] = []
    /// True when nothing local is left and the group exists only for foreign sessions:
    /// the account is not on this Mac, or has none of its own running.
    var isForeignOnly = false

    var count: Int { sessions.count + unmanaged.count }
    var foreignCount: Int { foreign.count }
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
                       unmanaged: [ClaudeSessionInfo],
                       live: [Int32: ClaudeSessionInfo] = [:],
                       foreign: [ForeignSession] = []) -> [SessionGroup] {
        var byAccount: [String: [SessionRecord]] = [:]
        for session in sessions {
            byAccount[session.accountID, default: []].append(session)
        }
        var foreignByAccount: [String: [ForeignSession]] = [:]
        for session in foreign {
            foreignByAccount[session.accountID, default: []].append(session)
        }

        var groups: [SessionGroup] = []
        for account in accounts {
            let owned = byAccount.removeValue(forKey: account.id)
            let elsewhere = foreignByAccount.removeValue(forKey: account.id) ?? []
            guard owned != nil || !elsewhere.isEmpty else { continue }
            groups.append(SessionGroup(id: account.id,
                                       title: account.displayName,
                                       subtitle: account.subscriptionType,
                                       sessions: sorted(owned ?? [], live: live),
                                       unmanaged: [],
                                       foreign: ForeignSessions.sorted(elsewhere),
                                       isForeignOnly: owned == nil))
        }

        // A session whose account was removed still holds a proxy port, so it gets a
        // group of its own rather than disappearing from the only screen that lists it.
        for accountID in byAccount.keys.sorted() {
            groups.append(SessionGroup(id: accountID,
                                       title: "Unknown account",
                                       subtitle: String(accountID.prefix(8)),
                                       sessions: sorted(byAccount[accountID] ?? [],
                                                        live: live),
                                       unmanaged: [],
                                       foreign: ForeignSessions.sorted(
                                           foreignByAccount.removeValue(forKey: accountID) ?? [])))
        }

        // An account that only exists on another Mac. Titled from what that Mac called it
        // rather than from eight characters of UUID, which is the whole reason the label
        // travels on the wire.
        for accountID in foreignByAccount.keys.sorted() {
            let elsewhere = foreignByAccount[accountID] ?? []
            groups.append(SessionGroup(id: accountID,
                                       title: elsewhere.first?.accountLabel
                                           ?? "Unknown account",
                                       subtitle: "not on this Mac",
                                       sessions: [],
                                       unmanaged: [],
                                       foreign: ForeignSessions.sorted(elsewhere),
                                       isForeignOnly: true))
        }

        if !unmanaged.isEmpty {
            groups.append(SessionGroup(id: unmanagedGroupID,
                                       title: "Not managed by ccmux",
                                       subtitle: nil,
                                       sessions: [],
                                       unmanaged: sortedUnmanaged(unmanaged)))
        }
        return groups
    }
}

extension SessionGrouping {
    /// What a session is doing, ranked by how much it wants the user.
    ///
    /// `waiting` outranks `busy` deliberately: a working session needs nothing, while a
    /// blocked one is asking a question and will sit there until it is answered. Claude
    /// Code maps the same status to a tempo of "blocked".
    enum Activity: Int, Comparable {
        case waiting = 0
        case busy = 1
        case other = 2
        case idle = 3

        init(status: String?) {
            switch status {
            case "waiting": self = .waiting
            case "busy": self = .busy
            case "idle", nil: self = .idle
            default: self = .other
            }
        }

        static func < (lhs: Activity, rhs: Activity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Most-wanting-attention first, and within one tier the most recently active first.
    /// A session with no known time sorts last in its tier rather than first, so an
    /// unknown never outranks a measured one.
    static func sorted(_ records: [SessionRecord],
                       live: [Int32: ClaudeSessionInfo]) -> [SessionRecord] {
        records.sorted { a, b in
            let (infoA, infoB) = (live[a.pid], live[b.pid])
            let (rankA, rankB) = (Activity(status: infoA?.status),
                                  Activity(status: infoB?.status))
            if rankA != rankB { return rankA < rankB }
            let timeA = infoA?.updatedAt ?? .distantPast
            let timeB = infoB?.updatedAt ?? .distantPast
            if timeA != timeB { return timeA > timeB }
            return a.startedAt > b.startedAt
        }
    }

    static func sortedUnmanaged(_ infos: [ClaudeSessionInfo]) -> [ClaudeSessionInfo] {
        infos.sorted { a, b in
            let (rankA, rankB) = (Activity(status: a.status), Activity(status: b.status))
            if rankA != rankB { return rankA < rankB }
            let timeA = a.updatedAt ?? a.startedAt ?? .distantPast
            let timeB = b.updatedAt ?? b.startedAt ?? .distantPast
            return timeA > timeB
        }
    }
}
