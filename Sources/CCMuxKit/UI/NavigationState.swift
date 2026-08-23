import SwiftUI

/// Which screen is showing and which session groups are folded away. Lives above the
/// pages so the Accounts screen can send you to a specific group on the Sessions screen.
@MainActor
final class NavigationState: ObservableObject {
    @Published var page: Page = .accounts
    /// Collapsed rather than expanded, so a group that appears later — a new account, or
    /// the unmanaged one — starts open without anyone having to register it first.
    @Published private(set) var collapsedGroups: Set<String> = []

    func isCollapsed(_ groupID: String) -> Bool { collapsedGroups.contains(groupID) }

    func toggle(_ groupID: String) {
        if collapsedGroups.remove(groupID) == nil { collapsedGroups.insert(groupID) }
    }

    /// Forgets groups that no longer exist. Without this, collapsing an account's group
    /// and letting its sessions end leaves the id behind, so the group returns folded
    /// over a session the user has never seen.
    func retainOnly(_ groupIDs: Set<String>) {
        let kept = collapsedGroups.intersection(groupIDs)
        if kept != collapsedGroups { collapsedGroups = kept }
    }

    /// The group to bring to the top of the Sessions screen. Consumed once, so returning
    /// to the screen later does not yank the scroll position again.
    @Published private(set) var scrollTarget: String?

    func showSessions(forAccount accountID: String) {
        collapsedGroups.remove(accountID)
        scrollTarget = accountID
        page = .sessions
    }

    func clearScrollTarget() {
        if scrollTarget != nil { scrollTarget = nil }
    }
}
