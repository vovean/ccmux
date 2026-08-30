import CCMuxCore
import Foundation

/// SHA-256 of each API key, by account.
///
/// Cached because every entry costs a Keychain read (~11ms, blocking, on the main actor)
/// and it is consulted on every reporting tick. A type of its own so the part that is easy
/// to get wrong is testable without a Keychain: the cache must remember which accounts it
/// *looked at*, not which ones it managed to read. Keying the check off the results means
/// one unreadable item can never be accounted for, and the whole cache is rebuilt on every
/// tick forever — the exact cost it exists to avoid.
struct APIKeyFingerprintCache: Equatable {
    private(set) var byAccount: [String: String] = [:]
    private var scope: Set<String> = []

    subscript(accountID: String) -> String? { byAccount[accountID] }

    /// Account id by fingerprint, for matching a foreign session's key to a local account.
    var byFingerprint: [String: String] {
        var out: [String: String] = [:]
        for (accountID, fingerprint) in byAccount { out[fingerprint] = accountID }
        return out
    }

    /// Rebuilds only when the set of accounts has moved. Returns whether it did, so a
    /// caller — or a test — can tell a rebuild from a skip.
    @discardableResult
    mutating func refresh(accountIDs: Set<String>,
                          reading read: (String) -> String?) -> Bool {
        guard accountIDs != scope else { return false }
        var fresh: [String: String] = [:]
        for accountID in accountIDs {
            guard let key = read(accountID), !key.isEmpty else { continue }
            fresh[accountID] = key.apiKeyFingerprint
        }
        byAccount = fresh
        scope = accountIDs
        return true
    }

    /// Forces the next refresh to re-read. Needed when a key changes under an id that did
    /// not, which the account set alone cannot show.
    ///
    /// Drops the answers as well as the scope. Clearing only the scope leaves them in
    /// place when the next refresh has nothing to look at — an empty set equals the
    /// cleared scope and short-circuits — so a fingerprint for a deleted account would
    /// survive indefinitely, which is the mirror of what this type exists to prevent.
    mutating func invalidate() {
        scope = []
        byAccount = [:]
    }
}
