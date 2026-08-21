import Foundation

/// Everything ccmux persists, loaded once and written through on change.
public final class Store {
    public private(set) var accounts: [Account]
    public private(set) var usage: [String: UsageSnapshot]
    public private(set) var sessions: [SessionRecord]
    public private(set) var settings: Settings

    private let lock = NSLock()

    public init() {
        try? Paths.ensureSupportTree()
        accounts = JSONStore.load([Account].self, from: Paths.accountsFile) ?? []
        usage = JSONStore.load([String: UsageSnapshot].self, from: Paths.usageFile) ?? [:]
        sessions = JSONStore.load([SessionRecord].self, from: Paths.sessionsFile) ?? []
        settings = JSONStore.load(Settings.self, from: Paths.settingsFile) ?? Settings()
    }

    // MARK: - Accounts

    public func allAccounts() -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return accounts
    }

    public func account(_ id: String) -> Account? {
        lock.lock(); defer { lock.unlock() }
        return accounts.first { $0.id == id }
    }

    public func upsert(_ account: Account) {
        lock.lock()
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        let snapshot = accounts
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.accountsFile)
    }

    public func removeAccount(_ id: String) {
        lock.lock()
        accounts.removeAll { $0.id == id }
        usage.removeValue(forKey: id)
        let accountsSnapshot = accounts
        let usageSnapshot = usage
        lock.unlock()
        JSONStore.save(accountsSnapshot, to: Paths.accountsFile)
        JSONStore.save(usageSnapshot, to: Paths.usageFile)
    }

    @discardableResult
    public func mutateAccount(_ id: String, _ body: (inout Account) -> Void) -> Account? {
        lock.lock()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        body(&accounts[index])
        let updated = accounts[index]
        let snapshot = accounts
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.accountsFile)
        return updated
    }

    // MARK: - Usage

    public func usage(for id: String) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return usage[id]
    }

    public func setUsage(_ snapshot: UsageSnapshot, for id: String) {
        lock.lock()
        usage[id] = snapshot
        let all = usage
        lock.unlock()
        JSONStore.save(all, to: Paths.usageFile)
    }

    public func allUsage() -> [String: UsageSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return usage
    }

    // MARK: - Sessions

    public func allSessions() -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return sessions
    }

    public func session(_ id: String) -> SessionRecord? {
        lock.lock(); defer { lock.unlock() }
        return sessions.first { $0.id == id }
    }

    public func upsert(_ session: SessionRecord) {
        lock.lock()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        let snapshot = sessions
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.sessionsFile)
    }

    public func removeSession(_ id: String) {
        lock.lock()
        sessions.removeAll { $0.id == id }
        let snapshot = sessions
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.sessionsFile)
    }

    @discardableResult
    public func mutateSession(_ id: String,
                              _ body: (inout SessionRecord) -> Void) -> SessionRecord? {
        lock.lock()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        body(&sessions[index])
        let updated = sessions[index]
        let snapshot = sessions
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.sessionsFile)
        return updated
    }

    // MARK: - Settings

    public func updateSettings(_ body: (inout Settings) -> Void) -> Settings {
        lock.lock()
        body(&settings)
        let snapshot = settings
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.settingsFile)
        return snapshot
    }

    public func currentSettings() -> Settings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }
}
