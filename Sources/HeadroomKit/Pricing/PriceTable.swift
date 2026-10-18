import Foundation

/// Per-1M-token rates for one model at the Standard tier (PLAN §6).
/// The same schema is used by the bundled `pricing.json` and the user's `pricing.override.json`.
public struct ModelRates: Codable, Sendable, Hashable {
    public var input: Double
    public var cacheWrite5m: Double
    /// Claude's 1-hour cache write. Providers with a single cache-write rate omit it.
    public var cacheWrite1h: Double?
    public var cacheRead: Double
    public var output: Double
    public var longContext: LongContextTier?
    /// Speed premiums keyed by `Speed.rawValue` (`fast`, `ultrafast`). They multiply every token class.
    public var speed: [String: Double]?

    public init(
        input: Double,
        cacheWrite5m: Double,
        cacheWrite1h: Double? = nil,
        cacheRead: Double,
        output: Double,
        longContext: LongContextTier? = nil,
        speed: [String: Double]? = nil
    ) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.longContext = longContext
        self.speed = speed
    }

    enum CodingKeys: String, CodingKey {
        case input
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
        case cacheRead = "cache_read"
        case output
        case longContext = "long_context"
        case speed
    }

    /// `input` and `output` are required; a missing cache-write or cache-read rate falls back to the input rate,
    /// so a short override such as `{"input": 0.6, "output": 2.2}` is enough to price a proxy model.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Double.self, forKey: .input)
        output = try c.decode(Double.self, forKey: .output)
        cacheWrite5m = try c.decodeIfPresent(Double.self, forKey: .cacheWrite5m) ?? input
        cacheWrite1h = try c.decodeIfPresent(Double.self, forKey: .cacheWrite1h)
        cacheRead = try c.decodeIfPresent(Double.self, forKey: .cacheRead) ?? input
        longContext = try c.decodeIfPresent(LongContextTier.self, forKey: .longContext)
        speed = try c.decodeIfPresent([String: Double].self, forKey: .speed)
    }

    /// Rates that apply to a request with `promptTokens` tokens of prompt.
    public func resolved(promptTokens: Int64) -> ResolvedRates {
        let base = ResolvedRates(
            input: input,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h ?? cacheWrite5m,
            cacheRead: cacheRead,
            output: output
        )
        guard let tier = longContext, promptTokens > tier.abovePromptTokens else { return base }
        let inMul = tier.inputMultiplier ?? 1
        let cacheMul = tier.cacheMultiplier ?? 1
        let outMul = tier.outputMultiplier ?? 1
        return ResolvedRates(
            input: tier.input ?? base.input * inMul,
            cacheWrite5m: tier.cacheWrite5m ?? base.cacheWrite5m * cacheMul,
            cacheWrite1h: tier.cacheWrite1h ?? tier.cacheWrite5m ?? base.cacheWrite1h * cacheMul,
            cacheRead: tier.cacheRead ?? base.cacheRead * cacheMul,
            output: tier.output ?? base.output * outMul
        )
    }
}

/// Premium tier for long prompts. Either absolute rates or multipliers of the base rates.
public struct LongContextTier: Codable, Sendable, Hashable {
    /// The tier applies when the request's prompt is strictly larger than this.
    public var abovePromptTokens: Int64
    public var input: Double?
    public var cacheWrite5m: Double?
    public var cacheWrite1h: Double?
    public var cacheRead: Double?
    public var output: Double?
    public var inputMultiplier: Double?
    /// Applies to cache writes and cache reads.
    public var cacheMultiplier: Double?
    public var outputMultiplier: Double?

    public init(
        abovePromptTokens: Int64,
        input: Double? = nil,
        cacheWrite5m: Double? = nil,
        cacheWrite1h: Double? = nil,
        cacheRead: Double? = nil,
        output: Double? = nil,
        inputMultiplier: Double? = nil,
        cacheMultiplier: Double? = nil,
        outputMultiplier: Double? = nil
    ) {
        self.abovePromptTokens = abovePromptTokens
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.inputMultiplier = inputMultiplier
        self.cacheMultiplier = cacheMultiplier
        self.outputMultiplier = outputMultiplier
    }

    enum CodingKeys: String, CodingKey {
        case abovePromptTokens = "above_prompt_tokens"
        case input
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
        case cacheRead = "cache_read"
        case output
        case inputMultiplier = "input_multiplier"
        case cacheMultiplier = "cache_multiplier"
        case outputMultiplier = "output_multiplier"
    }
}

/// Concrete per-1M rates after the long-context rule; one dollar per 1M tokens is one micro-dollar per token.
public struct ResolvedRates: Sendable, Hashable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double
}

/// The versioned rate card: bundled `pricing.json`, optionally merged with a user override.
public struct PriceTable: Codable, Sendable, Hashable {
    /// Date the rates were checked, e.g. `2026-10-18`.
    public var asOf: String
    public var models: [String: ModelRates]
    /// Bare names (`opus`, `sonnet`) mapped to a full model ID.
    public var aliases: [String: String]

    public init(asOf: String, models: [String: ModelRates], aliases: [String: String] = [:]) {
        self.asOf = asOf
        self.models = models
        self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case models
        case aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf) ?? ""
        let raw = try c.decodeIfPresent([String: ModelRates].self, forKey: .models) ?? [:]
        models = Dictionary(raw.map { (ModelID.canonicalKey($0.key), $0.value) }, uniquingKeysWith: { _, b in b })
        let rawAliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        aliases = Dictionary(rawAliases.map { ($0.key.lowercased(), ModelID.canonicalKey($0.value)) }, uniquingKeysWith: { _, b in b })
    }

    /// The rate card shipped inside the app.
    public static func bundled() throws -> PriceTable {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PriceTable {
        try JSONDecoder().decode(PriceTable.self, from: data)
    }

    /// Override models replace bundled rows with the same ID and add new ones; aliases merge the same way.
    /// The override's `as_of` wins only when it sets one.
    public func merging(_ override: PriceTable) -> PriceTable {
        var merged = self
        for (id, rates) in override.models { merged.models[id] = rates }
        for (alias, target) in override.aliases { merged.aliases[alias] = target }
        if !override.asOf.isEmpty { merged.asOf = override.asOf }
        return merged
    }

    /// Bundled rates merged with the override at `overrideURL`. A missing or malformed override is ignored.
    public static func load(overrideURL: URL?) -> PriceTable {
        let base = (try? bundled()) ?? PriceTable(asOf: "", models: [:], aliases: ModelID.defaultAliases)
        guard let overrideURL,
              let data = try? Data(contentsOf: overrideURL),
              let override = try? decode(data)
        else { return base }
        return base.merging(override)
    }

    /// Rates for a raw model name from a log, after normalization. Nil when the model is unpriced.
    public func rates(for rawModel: String) -> ModelRates? {
        models[ModelID.normalize(rawModel, aliases: aliases)]
    }

    /// The overrides file location used by the app.
    public static var defaultOverrideURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Headroom/pricing.override.json")
    }
}
