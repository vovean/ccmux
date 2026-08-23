import Foundation

extension Array where Element: Identifiable {
    /// Replaces the element with the same id, or appends. The three places that need
    /// this — accounts, sessions, and the usage-window merge — all key on `id`.
    mutating func upsert(_ element: Element) {
        if let index = firstIndex(where: { $0.id == element.id }) {
            self[index] = element
        } else {
            append(element)
        }
    }
}

/// A lock-protected, file-backed collection. One shape for every persisted entity, so
/// the locking and save discipline exist once.
public final class Table<Element: Codable & Identifiable> where Element.ID == String {
    private let url: URL
    private let lock = NSLock()
    private var items: [Element]
    var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
        items = JSONStore.load([Element].self, from: url) ?? []
    }

    public func all() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func get(_ id: String) -> Element? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    public func contains(where predicate: (Element) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains(where: predicate)
    }

    public func filter(_ isIncluded: (Element) -> Bool) -> [Element] {
        lock.lock(); defer { lock.unlock() }
        return items.filter(isIncluded)
    }

    public func upsert(_ element: Element) {
        write { $0.upsert(element) }
    }

    public func remove(_ id: String) {
        write { $0.removeAll { $0.id == id } }
    }

    @discardableResult
    public func mutate(_ id: String, _ body: (inout Element) -> Void) -> Element? {
        var updated: Element?
        write { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            body(&items[index])
            updated = items[index]
        }
        return updated
    }

    private func write(_ body: (inout [Element]) -> Void) {
        lock.lock()
        body(&items)
        let snapshot = items
        // Persisted under the same lock: releasing it first lets two writers save out of
        // order, so an older session assignment can land on disk after a newer one and
        // the next launch restores the stale account.
        JSONStore.save(snapshot, to: url)
        lock.unlock()
        onChange?()
    }
}

/// Everything ccmux persists, loaded once and written through on change.
public final class Store {
    /// Fired after any mutation. One hook rather than a `reload()` at every call site,
    /// which is the difference between the UI lagging and not when a new mutator is
    /// added.
    public var onChange: (() -> Void)? {
        didSet {
            accounts.onChange = { [weak self] in self?.onChange?() }
            sessions.onChange = { [weak self] in self?.onChange?() }
        }
    }

    public let accounts: Table<Account>
    public let sessions: Table<SessionRecord>

    private var usageByAccount: [String: UsageSnapshot]
    private var settings: Settings
    private let lock = NSLock()

    public init() {
        try? Paths.ensureSupportTree()
        accounts = Table(url: Paths.accountsFile)
        sessions = Table(url: Paths.sessionsFile)
        usageByAccount = JSONStore.load([String: UsageSnapshot].self, from: Paths.usageFile) ?? [:]
        settings = JSONStore.load(Settings.self, from: Paths.settingsFile) ?? Settings()
    }

    // MARK: - Accounts and sessions

    public func removeAccount(_ id: String) {
        accounts.remove(id)
        lock.lock()
        usageByAccount.removeValue(forKey: id)
        let snapshot = usageByAccount
        lock.unlock()
        JSONStore.save(snapshot, to: Paths.usageFile)
    }

    public func sessions(forAccount accountID: String) -> [SessionRecord] {
        sessions.filter { $0.accountID == accountID }
    }

    /// Whether any live session is using this account. The poller, the threshold check
    /// and the Accounts screen all need the same answer.
    public func isInUse(_ accountID: String) -> Bool {
        sessions.contains { $0.accountID == accountID }
    }

    // MARK: - Usage

    public func usage(for id: String) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return usageByAccount[id]
    }

    public func setUsage(_ snapshot: UsageSnapshot, for id: String) {
        lock.lock()
        usageByAccount[id] = snapshot
        // Saved under the lock, like Table.write: releasing first lets two writers persist
        // out of order and an older snapshot land on disk after a newer one.
        JSONStore.save(usageByAccount, to: Paths.usageFile)
        lock.unlock()
        onChange?()
    }

    public func allUsage() -> [String: UsageSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return usageByAccount
    }

    // MARK: - Settings

    public func updateSettings(_ body: (inout Settings) -> Void) -> Settings {
        lock.lock()
        body(&settings)
        let snapshot = settings
        JSONStore.save(snapshot, to: Paths.settingsFile)
        lock.unlock()
        onChange?()
        return snapshot
    }

    public func currentSettings() -> Settings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }
}
