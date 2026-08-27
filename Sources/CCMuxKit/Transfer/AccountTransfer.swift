import Foundation

/// Deciding what an import would do, before it does any of it.
public enum AccountTransfer {
    public enum Disposition: String, Equatable {
        /// A subscription that is not here yet. Needs a sign-in of its own — its
        /// credential cannot be carried, only re-created.
        case signIn
        /// An API key that travelled with the file. Verified, then stored.
        case addKey
        /// An API key whose file was exported without secrets.
        case needsKey
        /// Already on this machine. Left exactly as it is.
        case present

        public var summary: String {
            switch self {
            case .signIn: return "sign in"
            case .addKey: return "add API key"
            case .needsKey: return "paste API key"
            case .present: return "already here"
            }
        }
    }

    public struct Step: Equatable, Identifiable {
        public var entry: AccountBundle.Entry
        public var disposition: Disposition
        public var id: String { entry.id }
    }

    public struct Plan: Equatable {
        public var steps: [Step]

        /// Everything that needs the user to do something, in the order it is offered.
        public var actionable: [Step] { steps.filter { $0.disposition != .present } }
        public var present: [Step] { steps.filter { $0.disposition == .present } }
        public var isEmpty: Bool { actionable.isEmpty }
    }

    public static func plan(_ bundle: AccountBundle, existing: [Account]) -> Plan {
        var seen = Set<String>()
        return Plan(steps: bundle.accounts
            // A hand-edited file can repeat an id, and two rows with one identity make
            // SwiftUI's ForEach misrender.
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.priority < $1.priority }
            .map { entry in
                Step(entry: entry, disposition: disposition(for: entry, existing: existing))
            })
    }

    static func disposition(for entry: AccountBundle.Entry,
                            existing: [Account]) -> Disposition {
        // Never overwrite: an account already here has a working sign-in, and replacing
        // it would at best re-do work and at worst break the lineage it is using.
        if matches(entry, in: existing) != nil { return .present }
        guard entry.kind == .apiKey else { return .signIn }
        return (entry.apiKey?.isEmpty == false) ? .addKey : .needsKey
    }

    /// Matched on the Anthropic account id first, which is identical on every machine.
    /// Email is the fallback for a record written before an id was known, and for an
    /// API-key account, whose id is generated locally and so differs per machine.
    static func matches(_ entry: AccountBundle.Entry, in existing: [Account]) -> Account? {
        if let byID = existing.first(where: { $0.id == entry.id }) { return byID }
        guard let email = entry.email?.lowercased(), !email.isEmpty else { return nil }
        return existing.first { $0.email?.lowercased() == email }
    }

    // MARK: - Building an export

    public static func bundle(accounts: [Account], settings: Settings,
                              profiles: [ChromeProfile],
                              includePolicies: Bool,
                              apiKey: (String) -> String?) -> AccountBundle {
        let byDirectory = Dictionary(profiles.map { ($0.directory, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let entries = accounts.map { account -> AccountBundle.Entry in
            let profile = account.chromeProfileDirectory.flatMap { byDirectory[$0] }
            return AccountBundle.Entry(
                id: account.id, label: account.label, email: account.email,
                organizationUUID: account.organizationUUID,
                organizationName: account.organizationName,
                subscriptionType: account.subscriptionType,
                rateLimitTier: account.rateLimitTier,
                priority: account.priority, inRotation: account.inRotation,
                kind: account.kind, monthlyBudgetUSD: account.monthlyBudgetUSD,
                chromeProfileName: profile?.name, chromeProfileEmail: profile?.email,
                // Subscriptions never carry a credential; the closure is only ever asked
                // about keys, and only when the export was asked for secrets.
                apiKey: account.kind == .apiKey ? apiKey(account.id) : nil)
        }
        return AccountBundle(accounts: entries,
                             policies: includePolicies ? settings.policies : nil,
                             thresholds: includePolicies
                                 ? AccountBundle.Thresholds(settings) : nil)
    }

    /// The account record an imported entry becomes. Usage, health and spend are not
    /// carried: they are facts about the other machine, and the first poll replaces them.
    public static func account(from entry: AccountBundle.Entry,
                               chromeProfileDirectory: String?) -> Account {
        Account(id: entry.id, label: entry.label, email: entry.email,
                organizationUUID: entry.organizationUUID,
                organizationName: entry.organizationName,
                subscriptionType: entry.subscriptionType,
                rateLimitTier: entry.rateLimitTier,
                priority: entry.priority,
                chromeProfileDirectory: chromeProfileDirectory,
                kind: entry.kind, inRotation: entry.inRotation,
                monthlyBudgetUSD: entry.monthlyBudgetUSD)
    }
}
