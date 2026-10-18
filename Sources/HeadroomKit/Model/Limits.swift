import Foundation

/// One metered window reported by a provider: the 5-hour session, the weekly allowance,
/// or a model-scoped weekly cap (e.g. the Fable cap).
public struct LimitWindow: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case session
        case weekly
        case modelWeekly
    }

    /// Stable identifier, used to key glide samples: `session`, `weekly`, `model:<name>`.
    public var id: String
    public var kind: Kind
    /// Display name for scoped caps ("Fable", "GPT-6 Astra"). Nil for session and weekly.
    public var label: String?
    /// Used fraction of the window, clamped to 0…1.
    public var used: Double
    public var resetsAt: Date?
    /// Window length in seconds when the provider reports it (Codex does; Claude implies 5 h / 7 d).
    public var duration: TimeInterval?
    /// Claude's `is_active`: whether the scoped model is the one currently in use.
    public var isActive: Bool

    public init(
        id: String,
        kind: Kind,
        label: String? = nil,
        used: Double,
        resetsAt: Date?,
        duration: TimeInterval? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.used = min(max(used.isFinite ? used : 0, 0), 1)
        self.resetsAt = resetsAt
        self.duration = duration
        self.isActive = isActive
    }

    public var remaining: Double { 1 - used }

    /// Window length, falling back to the provider convention (5 h session, 7 d weekly).
    public var effectiveDuration: TimeInterval {
        if let duration, duration > 0 { return duration }
        switch kind {
        case .session: return 5 * 3600
        case .weekly, .modelWeekly: return 7 * 86400
        }
    }

    public var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-effectiveDuration) } }

    public static func sessionID() -> String { "session" }
    public static func weeklyID() -> String { "weekly" }
    public static func modelID(_ name: String) -> String {
        "model:" + name.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

/// A reset credit (Codex) or reset grant (Claude) that can restart a weekly window early.
/// Headroom only displays these; it never redeems one.
public struct ResetCredit: Codable, Sendable, Hashable {
    public var expiresAt: Date?
    public var grantedAt: Date?
    public var title: String?
    /// How many resets this entry holds (Claude grants carry `resets_left`; Codex credits are 1 each).
    public var count: Int

    public init(expiresAt: Date?, grantedAt: Date? = nil, title: String? = nil, count: Int = 1) {
        self.expiresAt = expiresAt
        self.grantedAt = grantedAt
        self.title = title
        self.count = max(count, 0)
    }
}

/// The plan behind a reading, for the pill and the plan-price comparison.
public struct PlanInfo: Codable, Sendable, Hashable {
    /// Raw plan identifier from the provider (`max_20x`, `team`, `pro`, `plus`, `free`, …).
    public var raw: String
    /// Claude's `rateLimitTier` when present (`default_claude_max_5x`).
    public var tier: String?
    /// Short uppercase label for the plan pill: `MAX 20×`, `PRO`, `TEAM`.
    public var pill: String
    public var isEnterprise: Bool
    /// Default monthly list price in USD, before any Settings override. Nil when unknown.
    public var monthlyPriceUSD: Double?

    public init(raw: String, tier: String? = nil, pill: String, isEnterprise: Bool = false, monthlyPriceUSD: Double? = nil) {
        self.raw = raw
        self.tier = tier
        self.pill = pill
        self.isEnterprise = isEnterprise
        self.monthlyPriceUSD = monthlyPriceUSD
    }

    /// Weekly share of the monthly price (12 months over 52 weeks).
    public var weeklyPriceUSD: Double? { monthlyPriceUSD.map { $0 * 12 / 52 } }
}

public enum ReadingSource: String, Codable, Sendable, Hashable {
    /// `api.anthropic.com/api/oauth/usage`
    case api
    /// `codex app-server` (spawned or the running daemon)
    case appServer
    /// `rate_limits` carried by a Codex session log line
    case passiveLog
    /// Parsed from `claude -p /usage` text output
    case cliText
}

/// Everything one limit read returned for one provider.
public struct LimitReading: Codable, Sendable, Hashable {
    public var provider: Provider
    public var fetchedAt: Date
    public var source: ReadingSource
    public var plan: PlanInfo?
    public var windows: [LimitWindow]
    public var resetCredits: [ResetCredit]
    /// Total available reset credits when the provider reports a count (may exceed `resetCredits.count`).
    public var resetCreditsAvailable: Int?
    /// Provider-reported blocking reason (Codex `rateLimitReachedType`), if any.
    public var blockedReason: String?
    /// Hashed account identity. Raw account IDs are never stored.
    public var accountKey: String?

    public init(
        provider: Provider,
        fetchedAt: Date,
        source: ReadingSource,
        plan: PlanInfo? = nil,
        windows: [LimitWindow],
        resetCredits: [ResetCredit] = [],
        resetCreditsAvailable: Int? = nil,
        blockedReason: String? = nil,
        accountKey: String? = nil
    ) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.source = source
        self.plan = plan
        self.windows = windows
        self.resetCredits = resetCredits
        self.resetCreditsAvailable = resetCreditsAvailable
        self.blockedReason = blockedReason
        self.accountKey = accountKey
    }

    public var session: LimitWindow? { windows.first { $0.kind == .session } }
    public var weekly: LimitWindow? { windows.first { $0.kind == .weekly } }
    public var modelCaps: [LimitWindow] { windows.filter { $0.kind == .modelWeekly } }

    /// The long window the hero describes: the all-models weekly limit, or, when a plan has none,
    /// the tightest model-scoped weekly cap (see PLAN §14.1).
    public var headline: LimitWindow? {
        if let weekly { return weekly }
        return modelCaps.max { a, b in
            if a.used != b.used { return a.used < b.used }
            return (a.resetsAt ?? .distantFuture) > (b.resetsAt ?? .distantFuture)
        }
    }

    public var totalResetCredits: Int {
        resetCreditsAvailable ?? resetCredits.reduce(0) { $0 + $1.count }
    }
}
