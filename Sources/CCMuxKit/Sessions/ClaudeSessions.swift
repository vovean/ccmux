import Foundation

/// Enumerates live Claude Code sessions from ~/.claude/sessions/<pid>.json, the same
/// files Claude Code uses to find its own peers.
public enum ClaudeSessions {
    public static func list() -> [ClaudeSessionInfo] {
        let dir = Paths.claudeSessionsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var result: [ClaudeSessionInfo] = []
        for name in names where name.hasSuffix(".json") {
            // The file is named <pid>.json, so a dead session can be skipped without
            // reading or parsing it — and stale files accumulate.
            guard let pid = Int32(name.dropLast(5)), isAlive(pid) else { continue }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            result.append(ClaudeSessionInfo(
                pid: pid,
                sessionID: obj["sessionId"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String,
                status: obj["status"] as? String,
                version: obj["version"] as? String,
                kind: obj["kind"] as? String,
                entrypoint: obj["entrypoint"] as? String,
                startedAt: (obj["startedAt"] as? Double)
                    .map { Date(timeIntervalSince1970: $0 / 1000) },
                updatedAt: (obj["updatedAt"] as? Double)
                    .map { Date(timeIntervalSince1970: $0 / 1000) }))
        }
        return result.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
