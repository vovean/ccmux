import CCMuxCore
import Foundation

/// Decides what one sync does to bring this Mac's accounts in line with the server's.
///
/// Pure, so every case is testable without a server; `Engine.syncAccounts` carries it
/// out. The end state is the same on every Mac: each account held by the server, and a
/// local record for each one this Mac has not removed for itself.
public enum AccountSync {
    public enum Action: Equatable, Sendable {
        /// Upload the lineage or key, then draw tokens from the server. Also for an account
        /// whose server copy needs signing in again while this Mac's works: the upload
        /// replaces the dead lineage there.
        case upload(localID: String)
        /// Held here and on the server: drop the local lineage and draw from the server.
        case handOver(localID: String, remoteID: String)
        case importAccount(remoteID: String)
        /// This Mac had handed it to the server, and the server no longer has it.
        case remove(localID: String)
        /// Already the server's: bring the record's details up to date.
        case refresh(remoteID: String)
    }

    public struct Plan: Equatable, Sendable {
        public var actions: [Action]
        /// Removals not carried out, because they looked like a server that lost its
        /// accounts rather than accounts someone deleted.
        public var heldBackRemovals: [String]

        public init(actions: [Action] = [], heldBackRemovals: [String] = []) {
            self.actions = actions
            self.heldBackRemovals = heldBackRemovals
        }
    }

    /// - Parameters:
    ///   - hidden: server ids removed from this Mac only; never imported again.
    ///   - canUpload: whether this Mac holds something the server could adopt — a live
    ///     refresh token or an API key.
    ///   - apiKeyFingerprint: SHA-256 of a local API key. A key account's id is minted
    ///     by whoever added it, so only the fingerprint matches one across machines.
    public static func plan(local: [Account], remote: [RemoteAccount],
                            delegated: Set<String>, hidden: Set<String>,
                            canUpload: (Account) -> Bool,
                            apiKeyFingerprint: (String) -> String?) -> Plan {
        var plan = Plan()
        var removals: [String] = []
        var matched: Set<String> = []

        for account in local {
            let match = remoteMatch(for: account, in: remote, fingerprint: apiKeyFingerprint)
            guard let match else {
                if delegated.contains(account.id) {
                    removals.append(account.id)
                } else if canUpload(account) {
                    plan.actions.append(.upload(localID: account.id))
                }
                continue
            }
            matched.insert(match.id)
            if delegated.contains(account.id) {
                plan.actions.append(.refresh(remoteID: match.id))
            } else if match.health == .needsRelogin {
                if canUpload(account) { plan.actions.append(.upload(localID: account.id)) }
            } else {
                plan.actions.append(.handOver(localID: account.id, remoteID: match.id))
            }
        }

        for account in remote where !matched.contains(account.id)
            && !hidden.contains(account.id) {
            plan.actions.append(.importAccount(remoteID: account.id))
        }

        // ccmuxd comes up with no accounts when its file is unreadable. Mirroring that
        // would delete every account on every Mac within a minute.
        if remote.isEmpty && removals.count > 1 {
            plan.heldBackRemovals = removals
        } else {
            plan.actions += removals.map { .remove(localID: $0) }
        }
        return plan
    }

    /// After an adopt whose answer was lost: the server's record, if the adopt landed. A
    /// copy still needing sign-in was there before it and proves nothing — taking it as
    /// proof would give up the only working refresh token for a dead one.
    static func adopted(_ account: Account, in remote: [RemoteAccount],
                        keyFingerprint: String?) -> RemoteAccount? {
        guard let match = remoteMatch(for: account, in: remote,
                                      fingerprint: { _ in keyFingerprint }),
              match.health != .needsRelogin else { return nil }
        return match
    }

    static func remoteMatch(for account: Account, in remote: [RemoteAccount],
                            fingerprint: (String) -> String?) -> RemoteAccount? {
        switch account.kind {
        case .subscription:
            // The Anthropic account UUID, identical on every machine.
            return remote.first { $0.id == account.id && $0.kind == .subscription }
        case .apiKey:
            // By id as well: a delegated key already carries the server's id, and a
            // Keychain read that fails must not read as "the server deleted it".
            if let byID = remote.first(where: { $0.id == account.id && $0.kind == .apiKey }) {
                return byID
            }
            guard let mine = fingerprint(account.id) else { return nil }
            return remote.first { $0.apiKeyFingerprint == mine && $0.kind == .apiKey }
        }
    }
}
