import Foundation

/// Atomic, 0600 JSON file persistence for the app's small state files.
public struct JSONStore {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.warn("could not decode \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        // Unique per call: two concurrent saves of the same file would otherwise race
        // on one temp path and lose a write.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let data = try encoder.encode(value)
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: tmp.path)
            // replaceItemAt wants something to replace. On Linux — where the server
            // writes accounts.json into a fresh data directory — a missing original
            // fails, and the error would only ever surface as a log line.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.error("could not save \(url.lastPathComponent): \(error)")
        }
    }
}
