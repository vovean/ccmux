import Foundation

/// Tokens billed for one request, in the shape the Messages API reports them.
public struct TokenUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public var isEmpty: Bool {
        input == 0 && output == 0 && cacheRead == 0
            && cacheWrite5m == 0 && cacheWrite1h == 0
    }
}

public struct ModelPrice: Equatable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    /// Promotional rates, and the day after which they stop applying.
    public var introInputPerMTok: Double?
    public var introOutputPerMTok: Double?
    public var introEndsAfter: String?

    public init(input: Double, output: Double, introInput: Double? = nil,
                introOutput: Double? = nil, introEndsAfter: String? = nil) {
        inputPerMTok = input
        outputPerMTok = output
        introInputPerMTok = introInput
        introOutputPerMTok = introOutput
        self.introEndsAfter = introEndsAfter
    }

    func rates(on date: Date) -> (input: Double, output: Double) {
        guard let introInput = introInputPerMTok,
              let introOutput = introOutputPerMTok,
              let endsAfter = introEndsAfter,
              let end = Pricing.day(endsAfter),
              date <= end.addingTimeInterval(86_400)
        else { return (inputPerMTok, outputPerMTok) }
        return (introInput, introOutput)
    }
}

/// First-party Claude API list prices, per million tokens. Kept as data so a price change
/// is a one-line edit rather than a hunt through the cost maths.
public enum Pricing {
    /// Uniform across models: a 5-minute cache write costs 1.25x input, a 1-hour write
    /// 2x, and a cache read a tenth.
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
    public static let cacheReadMultiplier = 0.1

    public static let table: [String: ModelPrice] = [
        "claude-fable-5": ModelPrice(input: 10, output: 50),
        "claude-mythos-5": ModelPrice(input: 10, output: 50),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25),
        "claude-sonnet-5": ModelPrice(input: 3, output: 15, introInput: 2,
                                      introOutput: 10, introEndsAfter: "2026-08-31"),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5),
    ]

    static func day(_ yyyymmdd: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: yyyymmdd)
    }

    /// Strips the decorations a response can carry — a date suffix, a `[1m]` context
    /// marker — so "claude-haiku-4-5-20251001" finds the "claude-haiku-4-5" entry.
    public static func normalize(_ modelID: String) -> String {
        var id = modelID.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[id.startIndex..<bracket]) }
        if table[id] != nil { return id }
        // Longest match wins, so "claude-opus-4-8" is not shadowed by a shorter key.
        let matches = table.keys.filter { id.hasPrefix($0) }
        return matches.max(by: { $0.count < $1.count }) ?? id
    }

    public static func price(for modelID: String) -> ModelPrice? {
        table[normalize(modelID)]
    }

    /// Dollars for one request, or nil when the model is not in the table — a wrong
    /// number here is worse than an absent one, so an unknown model is not guessed at.
    public static func cost(model: String, usage: TokenUsage,
                            on date: Date = Date()) -> Double? {
        guard let price = price(for: model) else { return nil }
        let rates = price.rates(on: date)
        let perToken = rates.input / 1_000_000
        return perToken * Double(usage.input)
            + rates.output / 1_000_000 * Double(usage.output)
            + perToken * cacheReadMultiplier * Double(usage.cacheRead)
            + perToken * cacheWrite5mMultiplier * Double(usage.cacheWrite5m)
            + perToken * cacheWrite1hMultiplier * Double(usage.cacheWrite1h)
    }
}
