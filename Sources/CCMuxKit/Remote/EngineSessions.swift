import CCMuxCore
import Foundation

/// Telling the account server what is running here, and reading back what is running
/// everywhere else.
///
/// The exchange is one request: a report is this Mac's whole list, and the answer is every
/// machine's. Nothing about a foreign session is persisted, and nothing about one is
/// actionable from here — there is no pid on this host to signal and no port to reach.
public extension Engine {
    /// Reports and re-reads, once. Called on the housekeeping tick.
    ///
    /// Reports unconditionally rather than only when something changed: the answer's
    /// staleness is measured from the last report, so a quiet Mac that stopped talking
    /// would fade out of everyone else's window while still running sessions.
    func syncSessions() async {
        guard let client = serverClient else {
            forgetForeignSessions()
            return
        }
        // The request timeout equals the housekeeping interval, so a server slow enough to
        // reach it would have two of these in flight — and the later answer landing first
        // stamps older machines with a fresher `fetchedAt`, reading younger than the truth.
        guard !syncingSessions else { return }
        syncingSessions = true
        defer { syncingSessions = false }
        refreshAPIKeyFingerprints()

        let report = ForeignSessions.report(
            label: machineIdentity.label,
            sessions: store.sessions.all(),
            live: liveByPID,
            accountLabels: Dictionary(store.accounts.all().map { ($0.id, $0.displayName) },
                                      uniquingKeysWith: { first, _ in first }),
            fingerprints: apiKeyFingerprints.byAccount)

        do {
            let response = try await client.reportSessions(machineID: machineIdentity.id,
                                                           report)
            foreignSnapshots = (response.machines, Date())
            if serverSupportsSessions != true { serverSupportsSessions = true }
            if sessionSyncFailing {
                sessionSyncFailing = false
                Log.info("session sync recovered")
            }
        } catch ServerClientError.unsupported {
            // Kept on the tick rather than latched off: upgrading the server should start
            // working on its own, and the cost of being wrong is one 404 every 20s.
            if serverSupportsSessions != false { serverSupportsSessions = false }
            if foreignSnapshots != nil { foreignSnapshots = nil }
        } catch {
            // The snapshots we hold are left alone deliberately: they keep ageing below,
            // so an unreachable server shows the other Macs going stale rather than
            // vanishing the instant the tunnel drops.
            if !sessionSyncFailing {
                sessionSyncFailing = true
                Log.info("session sync failed: \(error.localizedDescription)")
            }
        }
        resolveForeignSessions()
    }

    /// Rebuilds the visible list from whatever the last answer was, aged to now.
    ///
    /// Every machine's age is advanced by how long ago that answer arrived, which is what
    /// makes a machine fade while the server is unreachable instead of freezing at the
    /// staleness it had when contact was lost.
    func resolveForeignSessions(now: Date = Date()) {
        guard settings.showForeignSessions, let held = foreignSnapshots else {
            if !foreignSessions.isEmpty { foreignSessions = [] }
            return
        }
        let sinceFetch = max(0, now.timeIntervalSince(held.fetchedAt))
        let aged = held.machines.map { machine -> MachineSnapshot in
            var copy = machine
            copy.ageSeconds += sinceFetch
            return copy
        }
        let resolved = ForeignSessions.resolve(
            aged,
            excluding: machineIdentity.id,
            localAccountIDs: Set(store.accounts.all().map(\.id)),
            fingerprintToAccountID: apiKeyFingerprints.byFingerprint,
            now: now)
        if foreignSessions != resolved { foreignSessions = resolved }
    }

    func setShowForeignSessions(_ shown: Bool) {
        updateSettings { $0.showForeignSessions = shown }
        resolveForeignSessions()
    }

    func setMachineLabel(_ label: String) {
        machineIdentity = MachineIdentityStore.save(
            MachineIdentityStore.renamed(machineIdentity, to: label))
        Task { await syncSessions() }
    }

    /// Drops a machine's sessions from the server. For a Mac that is gone for good — one
    /// still running simply reports itself back within a tick.
    func forgetMachine(_ machineID: String) async {
        guard let client = serverClient else { return }
        try? await client.forgetMachine(machineID)
        foreignSnapshots?.machines.removeAll { $0.machineID == machineID }
        resolveForeignSessions()
    }

    /// Every write is guarded. `@Published` fires on assignment regardless of value, and
    /// this runs on every housekeeping tick of every Mac with no account server — so an
    /// unguarded nil would repaint the whole window twice a minute to say nothing.
    func forgetForeignSessions() {
        if foreignSnapshots != nil { foreignSnapshots = nil }
        if serverSupportsSessions != nil { serverSupportsSessions = nil }
        if !foreignSessions.isEmpty { foreignSessions = [] }
    }

    internal func refreshAPIKeyFingerprints() {
        let keyed = Set(store.accounts.all().filter { $0.kind == .apiKey }.map(\.id))
        apiKeyFingerprints.refresh(accountIDs: keyed) { accountID in
            (try? APIKeyStore.read(accountID)) ?? nil
        }
    }

    /// The machines currently contributing sessions, for Settings to list and for the
    /// account pill's tooltip.
    var foreignMachines: [(id: String, label: String, ageSeconds: TimeInterval)] {
        guard let held = foreignSnapshots else { return [] }
        let sinceFetch = max(0, Date().timeIntervalSince(held.fetchedAt))
        return held.machines
            .filter { $0.machineID != machineIdentity.id }
            .map { ($0.machineID, $0.label, $0.ageSeconds + sinceFetch) }
    }
}
