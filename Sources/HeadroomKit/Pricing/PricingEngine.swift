import Foundation

/// API-equivalent cost of some usage, in integer micro-dollars, split by token class.
public struct Cost: Codable, Sendable, Hashable {
    /// Total micro-dollars (1 USD = 1,000,000).
    public var micros: Int64
    /// False when the model has no rate-card row; its tokens are still counted elsewhere.
    public var priced: Bool
    public var input: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64
    public var output: Int64

    public init(input: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0, priced: Bool = true) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.micros = input + cacheWrite + cacheRead + output
        self.priced = priced
    }

    public static let zero = Cost()
    public static let unpriced = Cost(priced: false)

    public var dollars: Double { Double(micros) / 1_000_000 }

    /// Sum of two costs. The result is `priced` only when both parts were.
    public static func + (a: Cost, b: Cost) -> Cost {
        Cost(
            input: a.input + b.input,
            cacheWrite: a.cacheWrite + b.cacheWrite,
            cacheRead: a.cacheRead + b.cacheRead,
            output: a.output + b.output,
            priced: a.priced && b.priced
        )
    }

    public static func += (a: inout Cost, b: Cost) { a = a + b }
}

/// Prices usage events one at a time (PLAN §6). Long-context tiers depend on each request's own
/// prompt size, so pricing happens per event before anything is summed into buckets.
public struct PricingEngine: Sendable {
    public let table: PriceTable

    public init(table: PriceTable) {
        self.table = table
    }

    /// Bundled rates plus the user override, if present.
    public static func standard(overrideURL: URL? = PriceTable.defaultOverrideURL) -> PricingEngine {
        PricingEngine(table: .load(overrideURL: overrideURL))
    }

    public var asOf: String { table.asOf }

    public func isPriced(model: String) -> Bool { table.rates(for: model) != nil }

    public func price(_ event: UsageEvent) -> Cost {
        price(tokens: event.tokens, model: event.model, speed: event.speed)
    }

    public func price(tokens: TokenCounts, model: String, speed: Speed = .standard) -> Cost {
        guard let rates = table.rates(for: model) else { return .unpriced }
        let r = rates.resolved(promptTokens: tokens.prompt)
        let multiplier = speed == .standard ? 1 : (rates.speed?[speed.rawValue] ?? 1)
        func micros(_ count: Int64, _ rate: Double) -> Int64 {
            guard count > 0 else { return 0 }
            return Int64((Double(count) * rate * multiplier).rounded())
        }
        return Cost(
            input: micros(tokens.newInput, r.input),
            cacheWrite: micros(tokens.cacheWrite5m, r.cacheWrite5m) + micros(tokens.cacheWrite1h, r.cacheWrite1h),
            cacheRead: micros(tokens.cacheRead, r.cacheRead),
            output: micros(tokens.output, r.output)
        )
    }
}

/// Share of tokens on models without rates, for the cost footnote.
public struct UnpricedSummary: Sendable, Hashable {
    /// 0…1 share of all tokens that sit on unpriced models.
    public var share: Double
    /// Unpriced model names, most tokens first.
    public var models: [String]
    public var asOf: String

    public init(tokensByModel: [String: Int64], engine: PricingEngine) {
        asOf = engine.asOf
        let total = tokensByModel.values.reduce(0, +)
        let unpriced = tokensByModel.filter { $0.value > 0 && !engine.isPriced(model: $0.key) }
        let unpricedTotal = unpriced.values.reduce(0, +)
        share = total > 0 ? Double(unpricedTotal) / Double(total) : 0
        models = unpriced.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// "Rates as of 2026-10-18 · 2.1% of tokens on unpriced models (glm-5.3-flash)"
    public var footnote: String {
        var text = "Rates as of \(asOf)"
        if !models.isEmpty {
            let names = models.prefix(3).joined(separator: ", ") + (models.count > 3 ? ", …" : "")
            text += " · \(NumberFormat.percent(share)) of tokens on unpriced models (\(names))"
        }
        return text
    }
}

/// "This week: $412 at API rates ≈ 8.9× your plan's weekly price."
public enum PlanComparison {
    /// Weekly API cost divided by the plan's weekly price. `monthlyOverrideUSD` (from Settings) replaces
    /// the plan's list price. Nil when the price is unknown or zero.
    public static func multiple(weeklyCostMicros: Int64, plan: PlanInfo?, monthlyOverrideUSD: Double? = nil) -> Double? {
        let monthly = monthlyOverrideUSD ?? plan?.monthlyPriceUSD
        guard let monthly, monthly > 0 else { return nil }
        let weekly = monthly * 12 / 52
        return Double(weeklyCostMicros) / 1_000_000 / weekly
    }
}
