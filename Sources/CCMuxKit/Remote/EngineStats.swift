import CCMuxCore
import Foundation

/// Handing this Mac's token counts to the account server, and reading the fleet's back.
///
/// The two halves are deliberately on different clocks. Reporting rides the housekeeping
/// tick because a minute that has ended is worth nothing until it is somewhere durable;
/// reading happens only while the Stats page is on screen, because nobody is served by
/// pulling a month of series over a VPN tunnel to draw a window that is not open.
public extension Engine {
    /// Closes the minutes that have ended and pushes them. Called on the housekeeping
    /// tick, after the session report.
    func flushUsage(now: Date = Date()) async {
        guard let client = serverClient else {
            // Nowhere to send it and nothing local reads it, so holding a spool would be
            // a file that only ever grows.
            usageLedger.clear()
            saveUsageSpoolIfNeeded()
            return
        }
        usageLedger.closeElapsed(now: now)
        saveUsageSpoolIfNeeded()

        guard !pushingUsage else { return }
        pushingUsage = true
        defer { pushingUsage = false }

        await refreshServerFeatures(client, now: now)
        if serverSupportsUsageSeries == false {
            stopRecordingUsage()
            return
        }

        let batch = usageLedger.batch
        guard !batch.isEmpty else { return }
        do {
            try await client.reportUsage(machineID: machineIdentity.id,
                                         UsageReport(label: machineIdentity.label,
                                                     buckets: batch))
            usageLedger.acknowledge(batch)
            saveUsageSpoolIfNeeded()
            if serverSupportsUsageSeries != true { serverSupportsUsageSeries = true }
            if usageReportFailing {
                usageReportFailing = false
                Log.info("usage reporting recovered")
            }
        } catch ServerClientError.unsupported {
            // Recording stops until the next probe rather than for good: leaving it on
            // against a server that will never take the buckets fills a spool for weeks,
            // and leaving it off for good means an upgraded server is never noticed.
            if serverSupportsUsageSeries != false {
                serverSupportsUsageSeries = false
                Log.info("this ccmuxd does not collect usage — not recording it")
            }
            stopRecordingUsage()
        } catch {
            // Kept, not dropped: the spool is what carries them across an outage.
            if !usageReportFailing {
                usageReportFailing = true
                Log.info("usage reporting failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a request's counts are worth keeping. False once a server has said it
    /// does not collect them, so nothing accumulates with nowhere to go.
    var recordsUsage: Bool {
        isConnectedToServer && serverSupportsUsageSeries != false
    }

    internal func stopRecordingUsage() {
        usageLedger.clear()
        saveUsageSpoolIfNeeded()
    }

    internal func loadUsageSpool() {
        guard let spool = JSONStore.load(UsageLedger.Spool.self, from: Paths.usageSpoolFile)
        else { return }
        usageLedger = UsageLedger(spool)
    }

    /// Written only when something changed. In the ordinary case that is twice a minute
    /// with a handful of buckets in it; the file only gets big while the server is
    /// unreachable, which is exactly when it must not be rewritten for nothing.
    internal func saveUsageSpoolIfNeeded() {
        guard let spool = usageLedger.takeSpool() else { return }
        JSONStore.save(spool, to: Paths.usageSpoolFile)
    }

    // MARK: - Reading it back

    /// Called by the Stats page as it appears and leaves. Only while it is on screen does
    /// this Mac pull the fleet's series.
    func setStatsVisible(_ visible: Bool) {
        guard statsVisible != visible else { return }
        statsVisible = visible
        if visible { Task { await refreshStats() } }
    }

    func setStatsRange(_ range: UsageRange) {
        guard statsRange != range else { return }
        statsRange = range
        // Dropped rather than left showing: the axis is about to change under it, and a
        // month of points drawn on a day's grid is worse than an empty chart.
        stats = nil
        Task { await refreshStats() }
    }

    /// Fetches unless one is already in flight. Called on appear, on a range change, and
    /// from the one-minute tick while the page is up.
    ///
    /// Loops rather than returning when the range moved under it: the picker clears what
    /// is on screen, so an answer discarded for being the wrong range would otherwise
    /// leave the page blank until the next tick.
    func refreshStats(force: Bool = false) async {
        guard serverClient != nil, statsVisible || force else { return }
        guard !fetchingStats else { return }
        fetchingStats = true
        defer { fetchingStats = false }
        while true {
            guard let client = serverClient else { return }
            let range = statsRange
            do {
                let response = try await client.stats(range)
                guard range == statsRange else { continue }
                stats = response
                statsFetchedAt = Date()
                statsError = nil
                if serverSupportsUsageSeries != true { serverSupportsUsageSeries = true }
            } catch ServerClientError.unsupported {
                if serverSupportsUsageSeries != false { serverSupportsUsageSeries = false }
                stats = nil
                statsError = "This ccmuxd does not collect usage — upgrade the server."
            } catch {
                guard !Task.isCancelled else { return }
                guard range == statsRange else { continue }
                statsError = error.localizedDescription
            }
            return
        }
    }
}
