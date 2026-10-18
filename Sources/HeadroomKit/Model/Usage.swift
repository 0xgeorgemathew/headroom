import Foundation

/// Token counts normalized across providers (PLAN §5.3).
/// Claude: `input_tokens` → newInput, `cache_creation.ephemeral_5m/1h` → cacheWrite5m/1h,
/// `cache_read_input_tokens` → cacheRead, `output_tokens` → output.
/// Codex: newInput = input − cached − cacheWrite, cacheRead = cached, cacheWrite5m = cache_write,
/// output includes reasoning.
public struct TokenCounts: Codable, Sendable, Hashable {
    public var newInput: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var cacheRead: Int64
    public var output: Int64

    public init(newInput: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0) {
        self.newInput = newInput
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public static let zero = TokenCounts()

    public var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }
    /// Prompt size of the request: everything sent in, cached or not. Drives long-context tiers.
    public var prompt: Int64 { newInput + cacheWrite + cacheRead }
    public var total: Int64 { prompt + output }
    /// "New only" view: tokens that were not cache reads.
    public var fresh: Int64 { newInput + cacheWrite + output }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            newInput: a.newInput + b.newInput,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead,
            output: a.output + b.output
        )
    }

    public static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            newInput: a.newInput - b.newInput,
            cacheWrite5m: a.cacheWrite5m - b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h - b.cacheWrite1h,
            cacheRead: a.cacheRead - b.cacheRead,
            output: a.output - b.output
        )
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
    public static func -= (a: inout TokenCounts, b: TokenCounts) { a = a - b }
}

/// Speed tier recorded with a request. Codex logs don't record one, so Codex events are `.standard`.
public enum Speed: String, Codable, Sendable, Hashable {
    case standard
    case fast
    case ultrafast
}

/// One deduplicated model request read from a local log. Holds no prompt or response text.
public struct UsageEvent: Sendable, Hashable {
    public var provider: Provider
    public var timestamp: Date
    public var model: String
    /// Last path component of the working directory. Local-only; never shared.
    public var project: String?
    public var tokens: TokenCounts
    public var speed: Speed
    /// `message.id + requestId` (Claude) or `response_id` (Codex). Nil for legacy Codex records.
    public var dedupeKey: String?

    public init(
        provider: Provider,
        timestamp: Date,
        model: String,
        project: String? = nil,
        tokens: TokenCounts,
        speed: Speed = .standard,
        dedupeKey: String? = nil
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.tokens = tokens
        self.speed = speed
        self.dedupeKey = dedupeKey
    }
}
