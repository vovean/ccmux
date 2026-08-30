import CCMuxCore
import Foundation

/// How this Mac is named on the account server.
///
/// In its own file rather than in settings.json: settings are the thing people copy from
/// one Mac to another, and two machines reporting under one id would overwrite each
/// other's session list on every tick — each would see the other's sessions replaced by
/// its own and conclude the feature is broken.
public struct MachineIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum MachineIdentityStore {
    /// Reads the identity, minting one on first use.
    ///
    /// A failed write is not fatal but is worth noticing: the id would then differ on
    /// every launch, and the server would accumulate a ghost machine per restart until
    /// each aged out.
    public static func load() -> MachineIdentity {
        if let existing = JSONStore.load(MachineIdentity.self, from: Paths.machineFile),
           !existing.id.isEmpty {
            return existing
        }
        let fresh = MachineIdentity(id: UUID().uuidString, label: defaultLabel())
        // Not left to whoever ran first: `JSONStore.save` swallows a failed write, so
        // without the directory this mints a new id on every launch — one ghost machine
        // per restart, and at the server's cap those evict real Macs.
        try? Paths.ensureSupportTree()
        JSONStore.save(fresh, to: Paths.machineFile)
        return fresh
    }

    /// Renames the identity in hand. Pure, and takes the current one rather than reading
    /// it back: `JSONStore.save` returns nothing and swallows a write failure, so a
    /// `load()` here would mint a *fresh id* on an unwritable support directory — silently
    /// changing which machine this Mac is, and leaving a ghost on the server per rename.
    public static func renamed(_ identity: MachineIdentity, to label: String)
        -> MachineIdentity {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return MachineIdentity(id: identity.id,
                               label: trimmed.isEmpty ? defaultLabel() : trimmed)
    }

    @discardableResult
    public static func save(_ identity: MachineIdentity) -> MachineIdentity {
        try? Paths.ensureSupportTree()
        JSONStore.save(identity, to: Paths.machineFile)
        return identity
    }

    public static func defaultLabel() -> String {
        let name = Host.current().localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "This Mac" : name
    }
}
