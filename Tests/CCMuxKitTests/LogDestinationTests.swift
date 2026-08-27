import Foundation
import Testing
@testable import CCMuxCore

/// `Log` gained a configurable destination so the server could send lines to journald
/// instead of an app-support file. That made file logging opt-in, and for a while nothing
/// in the Mac app opted in — so ccmux.log silently stopped being written, while Settings
/// still showed its path and the README still documented it. Every diagnostic about a
/// credential going wrong lives in that file.
@Suite("Log destination", .serialized)
struct LogDestinationTests {
    @Test func configuringAFileMakesLinesLandInIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-log-\(UUID().uuidString).log")
        defer {
            Log.configure(fileURL: nil)
            try? FileManager.default.removeItem(at: url)
        }

        Log.configure(fileURL: url)
        let marker = "marker-\(UUID().uuidString)"
        Log.info(marker)

        // The write is queued, so it is waited for rather than asserted on the next line.
        var contents = ""
        for _ in 0..<200 {
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(marker) { break }
            usleep(10_000)
        }
        #expect(contents.contains(marker))
        #expect(contents.contains("INFO"))
    }

    /// The other half of the same change: with no destination configured, nothing is
    /// written anywhere on disk. This is what keeps the test suite out of the real log.
    @Test func withNoDestinationNothingIsWritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        Log.configure(fileURL: nil)
        Log.info("this must not create a file")
        usleep(100_000)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
