import CCMuxCore
import Foundation

/// Which accounts ccmux may choose on its own. One rule for every path that chooses, so
/// none of them can reach outside the group the others honour.
public enum AccountPool {
    /// A nil `group` means the accounts in no group: grouped accounts are reserved for
    /// the machines and launches that name their group. Membership is taken as the server
    /// sent it — a group this Mac has not loaded yet still reserves its accounts.
    public static func automatic(_ accounts: [Account], group: String?) -> [Account] {
        accounts.filter { $0.isAutoAssignable && $0.groupID == group }
    }

    /// The group a session chooses from: the one it was launched with, or this Mac's.
    public static func scope(of session: SessionRecord?, settings: Settings) -> String? {
        session?.groupID ?? settings.restrictedGroupID
    }

    /// The group named by a launch, by name (any case) or id.
    public static func resolve(_ name: String,
                               in groups: [SubscriptionGroup]) -> SubscriptionGroup? {
        groups.first { $0.id == name }
            ?? groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
