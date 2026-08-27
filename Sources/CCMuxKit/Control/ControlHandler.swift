import CCMuxCore
import Foundation

/// Serves the control socket. Deliberately not part of `Engine`.
///
/// `ControlServer` invokes its handler on a background queue. A closure written inside
/// the `@MainActor` Engine inherits main-actor isolation, and because `Handler` is not
/// `Sendable`, Swift 5 language mode does not diagnose the mismatch — so main-actor
/// state would be read and written from the control thread with no compiler complaint,
/// and the corruption would present as a SwiftUI bug. Everything reachable from here is
/// lock-protected instead.
public final class ControlHandler {
    private let store: Store
    private let sessions: SessionManager
    /// The one operation that genuinely needs the main actor. Returns nil on success or
    /// a message on failure.
    public var importGlobalLogin: (() async -> String?)?

    public init(store: Store, sessions: SessionManager) {
        self.store = store
        self.sessions = sessions
    }

    public func handle(_ request: ControlRequest) -> ControlResponse {
        switch request {
        case .ping:
            return .ok

        case .newSession(let policy, let cwd, let pid, let accountID):
            do {
                return .session(try sessions.createSession(policyName: policy, cwd: cwd,
                                                           pid: pid, accountID: accountID))
            } catch {
                return .failure(error.localizedDescription)
            }

        case .endSession(let sessionID):
            sessions.endSession(sessionID)
            return .ok

        case .assign(let sessionID, let accountID):
            do {
                try sessions.assign(sessionID: sessionID, accountID: accountID)
                return .ok
            } catch {
                return .failure(error.localizedDescription)
            }

        case .importGlobalLogin:
            guard let importGlobalLogin else { return .failure("ccmux is still starting up") }
            // The control connection is synchronous and the caller wants a real verdict,
            // so this thread waits — never the main actor, which is where the work runs.
            let semaphore = DispatchSemaphore(value: 0)
            var failure: String?
            Task {
                failure = await importGlobalLogin()
                semaphore.signal()
            }
            // Must exceed what the import actually awaits: a profile fetch plus a usage
            // fetch, each with a 15s timeout, on a slow network.
            guard semaphore.wait(timeout: .now() + 60) == .success else {
                return .failure("sign-in did not complete in time")
            }
            return failure.map { ControlResponse.failure($0) } ?? .ok

        case .status:
            let now = Date()
            let accounts = store.accounts.all().map { account in
                let snapshot = store.usage(for: account.id)
                return ControlAccountInfo(
                    id: account.id, label: account.displayName, email: account.email,
                    health: account.health.rawValue, windows: snapshot?.windows ?? [],
                    usageAge: snapshot.map { now.timeIntervalSince($0.fetchedAt) })
            }
            let sessionInfos = store.sessions.all().map { record in
                ControlSessionInfo(
                    sessionID: record.id, namespaceDir: record.namespaceDir.path,
                    port: record.port, accountID: record.accountID,
                    accountLabel: store.accounts.get(record.accountID)?.displayName
                        ?? record.accountID,
                    policyName: record.policyName, pid: record.pid)
            }
            return .status(ControlStatus(accounts: accounts, sessions: sessionInfos))
        }
    }
}
