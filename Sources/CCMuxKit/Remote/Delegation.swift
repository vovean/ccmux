import CCMuxCore
import Foundation

/// Works out what connecting to a server means for the accounts this Mac already holds.
///
/// Pure, so the interesting cases are testable without a server: the executor in
/// `Engine` does the mint-then-delete dance, this only decides what should happen.
public enum Delegation {
    public enum Disposition: String, Equatable, Sendable {
        /// Held here and on the server. Stop refreshing locally and pull tokens instead.
        case delegate
        /// Already delegated on an earlier connect; nothing to do.
        case alreadyDelegated
        /// Held only here. Pushing it up sends a refresh token, so it is never automatic.
        case pushCandidate
        /// Held only by the server. Import the metadata; tokens come on demand.
        case importable
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String
        public var displayName: String
        public var disposition: Disposition
        public var kind: AccountKind
        /// The server's id for this account, when it differs from the local one. Only an
        /// API-key account can differ: its id is a locally generated UUID.
        public var remoteID: String?

        public init(id: String, displayName: String, disposition: Disposition,
                    kind: AccountKind, remoteID: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.disposition = disposition
            self.kind = kind
            self.remoteID = remoteID
        }
    }

    public struct Plan: Equatable, Sendable {
        public var entries: [Entry]

        public init(entries: [Entry]) { self.entries = entries }

        public func entries(_ disposition: Disposition) -> [Entry] {
            entries.filter { $0.disposition == disposition }
        }

        public var isEmpty: Bool { entries.isEmpty }
    }

    /// - Parameters:
    ///   - delegated: accounts already handed over on an earlier connect.
    ///   - apiKeyFingerprint: SHA-256 of a local API-key account's key. A key account's
    ///     `id` is generated on the machine that added it, so two Macs holding the same
    ///     key disagree about its id and only the fingerprint can match them.
    public static func plan(local: [Account], remote: [RemoteAccount],
                            delegated: Set<String>,
                            apiKeyFingerprint: (String) -> String?) -> Plan {
        var entries: [Entry] = []
        var matchedRemoteIDs: Set<String> = []

        for account in local {
            let match = remoteMatch(for: account, in: remote, fingerprint: apiKeyFingerprint)
            if let match { matchedRemoteIDs.insert(match.id) }

            let disposition: Disposition
            if match == nil {
                disposition = .pushCandidate
            } else if delegated.contains(account.id) {
                disposition = .alreadyDelegated
            } else {
                disposition = .delegate
            }
            entries.append(Entry(id: account.id, displayName: account.displayName,
                                 disposition: disposition, kind: account.kind,
                                 remoteID: match?.id == account.id ? nil : match?.id))
        }

        for account in remote where !matchedRemoteIDs.contains(account.id) {
            entries.append(Entry(id: account.id, displayName: account.displayName,
                                 disposition: .importable, kind: account.kind))
        }
        return Plan(entries: entries)
    }

    private static func remoteMatch(for account: Account, in remote: [RemoteAccount],
                                    fingerprint: (String) -> String?) -> RemoteAccount? {
        switch account.kind {
        case .subscription:
            // The Anthropic account UUID, identical on every machine.
            return remote.first { $0.id == account.id && $0.kind == .subscription }
        case .apiKey:
            guard let mine = fingerprint(account.id) else { return nil }
            return remote.first { $0.apiKeyFingerprint == mine && $0.kind == .apiKey }
        }
    }
}
