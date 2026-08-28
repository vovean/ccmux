import CCMuxCore
import Foundation

public struct ChromeProfile: Identifiable, Hashable, Sendable {
    public var id: String { directory }
    public var directory: String        // "Default", "Profile 2", …
    public var name: String             // user-visible profile name
    public var email: String?           // nil when the profile isn't signed in

    public var label: String {
        if let email, !email.isEmpty { return "\(name) — \(email)" }
        return name
    }

    public init(directory: String, name: String, email: String?) {
        self.directory = directory
        self.name = name
        self.email = email
    }
}

public enum ChromeProfileReader {
    public static var localStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    public static func load() -> [ChromeProfile] {
        guard let data = try? Data(contentsOf: localStateURL) else { return [] }
        return parse(localState: data)
    }

    /// Parses Chrome's `Local State`. Defensive throughout: Chrome owns this schema
    /// and can change it, and a missing field must degrade to a hand-mappable profile
    /// rather than losing the row.
    public static func parse(localState data: Data) -> [ChromeProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        var out: [ChromeProfile] = []
        for (dir, raw) in cache {
            let info = raw as? [String: Any] ?? [:]
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
            out.append(ChromeProfile(directory: dir, name: name, email: email))
        }

        if let order = profile["profiles_order"] as? [String] {
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            out.sort {
                (rank[$0.directory] ?? Int.max, $0.name)
                    < (rank[$1.directory] ?? Int.max, $1.name)
            }
        } else {
            out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return out
    }
}
