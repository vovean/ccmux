import AppKit
import Foundation

/// Creating a Chrome profile for an account, and naming it.
///
/// Chrome owns `Local State` and rewrites it when it exits, so a name written underneath
/// a running Chrome is simply lost. Naming therefore only happens with Chrome quit, and
/// the file is backed up first — a corrupted `Local State` loses the user's whole profile
/// list, which is far worse than an unnamed profile.
public enum ChromeProfileWriter {
    public enum NameOutcome: Equatable {
        case named
        /// Chrome is running; the profile exists but keeps the name Chrome gives it.
        case skippedChromeRunning
        case failed(String)
    }

    public static var isChromeRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    /// The lowest `Profile N` Chrome is not already using. "Default" is never returned:
    /// it is the user's own profile and must not be repurposed.
    ///
    /// `alsoTaken` carries directories handed out but not yet visible: Chrome does not
    /// write a new profile into `Local State` until it commits, so two sign-ins a minute
    /// apart would otherwise both be sent to the same directory — and the second would
    /// land in a Chrome already signed into the first account.
    /// Chrome's own naming — "Person 2", "Profile 3", or the directory itself when a
    /// profile has no name. Such a name identifies nothing across machines, so it must
    /// never be treated as a match for an imported account.
    public static func isGenericName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "default" || lowered.hasPrefix("profile ") { return true }
        let parts = lowered.split(separator: " ")
        return parts.count == 2 && Int(parts[1]) != nil
    }

    public static func nextFreeDirectory(existing: [ChromeProfile],
                                         alsoTaken: [String] = []) -> String {
        let taken = Set(existing.map(\.directory)).union(alsoTaken)
        var index = 1
        while taken.contains("Profile \(index)") { index += 1 }
        return "Profile \(index)"
    }

    /// Chrome creates the directory itself the first time it is asked for one, so the
    /// profile is made by launching it at the page the user has to visit anyway.
    public static func create(directory: String, openingURL url: String)
        -> OpenOutcome {
        ChromeLauncher.open(url: url, profileDirectory: directory)
    }

    @discardableResult
    public static func name(directory: String, to name: String,
                            backingUp: Bool = true) -> NameOutcome {
        guard !isChromeRunning else { return .skippedChromeRunning }
        let url = ChromeProfileReader.localStateURL
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  var profile = root["profile"] as? [String: Any],
                  var cache = profile["info_cache"] as? [String: Any]
            else { return .failed("Chrome's Local State is not in the expected shape") }

            // Captured before the mutation: comparing the result against the dictionary
            // that produced it proves nothing.
            let before = Set(cache.keys)
            // Only a profile Chrome actually created is named. Inventing an entry would
            // put a profile the user never made into their Chrome picker — reachable by
            // starting a sign-in and cancelling it.
            guard var info = cache[directory] as? [String: Any] else {
                return .failed("Chrome has not created \(directory) yet")
            }
            info["name"] = name
            // Without this Chrome treats the name as auto-generated and replaces it with
            // the signed-in account's name on the next launch.
            info["is_using_default_name"] = false
            cache[directory] = info
            profile["info_cache"] = cache
            root["profile"] = profile

            let updated = try JSONSerialization.data(withJSONObject: root)
            // Chrome owns this schema and the round-trip goes through JSONSerialization,
            // so the result is checked against the list as it was read. Losing
            // `info_cache` would lose the user's whole profile list, which is far worse
            // than an unnamed profile.
            guard survivesRoundTrip(original: before, encoded: updated) else {
                return .failed("the rewritten profile list lost entries; left untouched")
            }
            if backingUp { try backup(data, of: url) }
            let mode = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try updated.write(to: url, options: .atomic)
            // An atomic write replaces by rename, so the new file carries the umask
            // rather than Chrome's own 0600.
            if let mode = mode ?? nil {
                try? FileManager.default.setAttributes([.posixPermissions: mode],
                                                       ofItemAtPath: url.path)
            }
            return .named
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func survivesRoundTrip(original: Set<String>, encoded: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return false }
        return Set(cache.keys) == original
    }

    /// One backup per naming run, not per profile: writing it before every profile would
    /// leave the last backup holding the state after all the earlier writes, which is no
    /// way back at all.
    private static func backup(_ data: Data, of url: URL) throws {
        let backupURL = url.appendingPathExtension("ccmux-backup")
        try data.write(to: backupURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: backupURL.path)
    }
}
