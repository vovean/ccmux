import Foundation

/// Pulls the billed token counts out of a response while it streams past.
///
/// The proxy never buffers a body — it relays chunks as they arrive — so the counts have
/// to be picked up in flight. In an SSE stream the input tokens arrive in `message_start`
/// and the final output count in `message_delta`; a non-streaming reply carries one JSON
/// object. Only lines mentioning `usage` are ever parsed, so the cost of watching is a
/// substring search per line.
public struct StreamingUsageTap {
    /// A single line larger than this is not a usage event, and buffering it would let a
    /// large non-streaming body sit in memory for nothing.
    static let maxLineBytes = 256 * 1024

    private var partial = Data()
    private var overflowed = false
    private var usage = TokenUsage()
    /// Set when a line was too big to inspect, so the caller can say the cost is unknown
    /// rather than reporting a confident zero.
    public private(set) var droppedOversizedLine = false

    public init() {}

    public var current: TokenUsage { usage }

    public mutating func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if !overflowed {
                partial.append(contentsOf: chunk[start..<newline])
                absorbLine()
            }
            partial.removeAll(keepingCapacity: true)
            overflowed = false
            start = chunk.index(after: newline)
        }
        guard start < chunk.endIndex else { return }
        if partial.count + chunk.distance(from: start, to: chunk.endIndex) > Self.maxLineBytes {
            overflowed = true
            droppedOversizedLine = true
            partial.removeAll(keepingCapacity: true)
            return
        }
        if !overflowed { partial.append(contentsOf: chunk[start...]) }
    }

    /// A non-streaming body has no trailing newline, so the last line only becomes
    /// readable once the response ends.
    public mutating func finish() {
        if !overflowed { absorbLine() }
        partial.removeAll(keepingCapacity: true)
        overflowed = false
    }

    private mutating func absorbLine() {
        guard !partial.isEmpty else { return }
        // Cheap reject before any JSON work: the overwhelming majority of SSE lines are
        // content deltas with no usage in them.
        guard partial.range(of: Data("usage".utf8)) != nil else { return }
        var slice = partial
        if let colon = slice.firstIndex(of: UInt8(ascii: ":")),
           slice.starts(with: Data("data:".utf8)) {
            slice = Data(slice[slice.index(after: colon)...])
        }
        guard let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any]
        else { return }
        // message_start nests it under `message`; message_delta and a plain reply do not.
        let holder = (object["message"] as? [String: Any]) ?? object
        guard let raw = holder["usage"] as? [String: Any] else { return }
        Self.merge(raw, into: &usage)
    }

    static func merge(_ raw: [String: Any], into usage: inout TokenUsage) {
        func int(_ key: String, _ dict: [String: Any]) -> Int? { dict[key] as? Int }
        // Input-side counts appear once, in message_start; output grows across deltas, so
        // the largest value seen is the final one.
        if let v = int("input_tokens", raw), v > 0 { usage.input = v }
        if let v = int("cache_read_input_tokens", raw), v > 0 { usage.cacheRead = v }
        if let breakdown = raw["cache_creation"] as? [String: Any] {
            if let v = int("ephemeral_5m_input_tokens", breakdown), v > 0 {
                usage.cacheWrite5m = v
            }
            if let v = int("ephemeral_1h_input_tokens", breakdown), v > 0 {
                usage.cacheWrite1h = v
            }
        } else if let v = int("cache_creation_input_tokens", raw), v > 0 {
            // Older shape with no 5m/1h split: bill it at the 5-minute rate.
            usage.cacheWrite5m = v
        }
        if let v = int("output_tokens", raw) { usage.output = max(usage.output, v) }
    }
}

/// Banks what a request cost, exactly once.
///
/// Anthropic bills for every token it produced before an abort, so cancelling a turn — the
/// commonest interaction there is — must still be paid for. Both the clean end and the
/// cancellation path flush through here, and the once-flag is what keeps that from
/// billing twice. An attempt that loses a failover race is voided instead: its tokens
/// belong to nobody, because the response was thrown away.
public final class BillingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var tap = StreamingUsageTap()
    private var settled = false
    private let emit: (TokenUsage) -> Void

    public init(emit: @escaping (TokenUsage) -> Void) {
        self.emit = emit
    }

    public func consume(_ data: Data) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        tap.consume(data)
        lock.unlock()
    }

    /// The response was discarded, so nothing here is owed.
    public func void() {
        lock.lock(); settled = true; lock.unlock()
    }

    public func flush() {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        tap.finish()
        let billed = tap.current
        let dropped = tap.droppedOversizedLine
        lock.unlock()
        if dropped {
            Log.warn("a response line was too large to read token counts from; "
                     + "this request's cost is not counted")
        }
        guard !billed.isEmpty else { return }
        emit(billed)
    }
}
