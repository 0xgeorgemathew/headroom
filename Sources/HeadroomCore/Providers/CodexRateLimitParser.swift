import Foundation
import HeadroomKit

/// What `account/read` says about the login.
public enum CodexAccountStatus: Sendable, Hashable {
    case chatgpt(planType: String?)
    case apiKey
    case otherProvider
    /// No account. `requiresAuth` distinguishes signed out from a provider that needs no login.
    case none(requiresAuth: Bool)

    public var fault: Fault? {
        switch self {
        case .chatgpt(let plan):
            return PlanCatalog.codex(planType: plan)?.isEnterprise == true ? .enterprise : nil
        case .apiKey:
            return .apiKeyLogin
        case .otherProvider:
            return .apiKeyLogin
        case .none(let requiresAuth):
            return requiresAuth ? .signedOut : nil
        }
    }
}

/// Parses app-server results (schema: `codex app-server generate-json-schema`, 0.163.0).
public enum CodexRateLimitParser {
    public static func account(_ result: [String: Any]) -> CodexAccountStatus {
        let requires = result["requiresOpenaiAuth"] as? Bool ?? true
        guard let account = result["account"] as? [String: Any], let type = account["type"] as? String else {
            return .none(requiresAuth: requires)
        }
        switch type {
        case "chatgpt": return .chatgpt(planType: account["planType"] as? String)
        case "apiKey": return .apiKey
        default: return .otherProvider
        }
    }

    public static func rateLimits(_ result: [String: Any], fetchedAt: Date) throws(ProviderFailure) -> LimitReading {
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        guard let main = (byID["codex"] ?? (result["rateLimits"] as? [String: Any])) else {
            throw ProviderFailure(.schemaDrift)
        }
        let mainID = main["limitId"] as? String ?? "codex"
        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = window(main[key], snake: false) else { continue }
            let kind: LimitWindow.Kind = w.minutes.map { $0 <= 360 } ?? false ? .session : .weekly
            guard !windows.contains(where: { $0.kind == kind }) else { continue }
            windows.append(LimitWindow(id: kind == .session ? LimitWindow.sessionID() : LimitWindow.weeklyID(), kind: kind,
                                       used: w.used, resetsAt: w.resetsAt, duration: w.minutes.map { Double($0) * 60 }))
        }
        for (limitID, snapshot) in byID.sorted(by: { $0.key < $1.key }) where limitID != "codex" && limitID != mainID {
            let label = (snapshot["limitName"] as? String) ?? (snapshot["normalModelSlug"] as? String) ?? limitID
            let candidates = ["secondary", "primary"].compactMap { window(snapshot[$0], snake: false) }
            guard let w = candidates.max(by: { ($0.minutes ?? 0) < ($1.minutes ?? 0) }) else { continue }
            windows.append(LimitWindow(id: LimitWindow.modelID(label), kind: .modelWeekly, label: label, used: w.used,
                                       resetsAt: w.resetsAt, duration: w.minutes.map { Double($0) * 60 }))
        }

        var credits: [ResetCredit] = []
        var available: Int?
        if let summary = result["rateLimitResetCredits"] as? [String: Any] {
            available = (summary["availableCount"] as? NSNumber)?.intValue
            for c in summary["credits"] as? [[String: Any]] ?? [] {
                guard (c["status"] as? String ?? "available") == "available" else { continue }
                credits.append(ResetCredit(
                    expiresAt: (c["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    grantedAt: (c["grantedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    title: c["title"] as? String,
                    count: 1
                ))
            }
            credits.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        }

        var blocked = main["rateLimitReachedType"] as? String
        if blocked == nil, (result["ordinaryUsageAllowed"] as? Bool) == false { blocked = "ordinary_usage_not_allowed" }
        let accountKey = (result["accountId"] as? String).flatMap { $0.isEmpty ? nil : AccountKey.make(prefix: "codex", parts: [$0]) }

        return LimitReading(
            provider: .codex,
            fetchedAt: fetchedAt,
            source: .appServer,
            plan: PlanCatalog.codex(planType: main["planType"] as? String),
            windows: windows,
            resetCredits: credits,
            resetCreditsAvailable: available,
            blockedReason: blocked,
            accountKey: accountKey
        )
    }

    struct Window {
        var used: Double
        var minutes: Int?
        var resetsAt: Date?
    }

    static func window(_ value: Any?, snake: Bool) -> Window? {
        guard let w = value as? [String: Any] else { return nil }
        let usedKey = snake ? "used_percent" : "usedPercent"
        let minutesKey = snake ? "window_minutes" : "windowDurationMins"
        let resetKey = snake ? "resets_at" : "resetsAt"
        guard let used = (w[usedKey] as? NSNumber)?.doubleValue else { return nil }
        return Window(
            used: used / 100,
            minutes: (w[minutesKey] as? NSNumber)?.intValue,
            resetsAt: (w[resetKey] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

/// `event_msg/token_count.rate_limits` from a Codex session log (PLAN §5.2, §14.3). The
/// ingestion layer only hands these over from sessions whose `model_provider` is `openai`.
public struct CodexPassiveRateLimits: Codable, Sendable, Hashable {
    public struct Window: Codable, Sendable, Hashable {
        public var used_percent: Double
        public var window_minutes: Int?
        public var resets_at: Int?

        public init(used_percent: Double, window_minutes: Int?, resets_at: Int?) {
            self.used_percent = used_percent
            self.window_minutes = window_minutes
            self.resets_at = resets_at
        }
    }

    public struct Credits: Codable, Sendable, Hashable {
        public var has_credits: Bool?
        public var unlimited: Bool?
        public var balance: String?
    }

    public var limit_id: String?
    public var primary: Window?
    public var secondary: Window?
    public var credits: Credits?
    public var plan_type: String?
    public var rate_limit_reached_type: String?

    public init(limit_id: String? = "codex", primary: Window?, secondary: Window?, credits: Credits? = nil,
                plan_type: String?, rate_limit_reached_type: String? = nil)
    {
        self.limit_id = limit_id
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.plan_type = plan_type
        self.rate_limit_reached_type = rate_limit_reached_type
    }

    /// Converts to a reading stamped with the log line's time.
    public func reading(at timestamp: Date, accountKey: String? = nil) -> LimitReading {
        var windows: [LimitWindow] = []
        for w in [primary, secondary].compactMap({ $0 }) {
            let kind: LimitWindow.Kind = (w.window_minutes ?? Int.max) <= 360 ? .session : .weekly
            guard !windows.contains(where: { $0.kind == kind }) else { continue }
            windows.append(LimitWindow(
                id: kind == .session ? LimitWindow.sessionID() : LimitWindow.weeklyID(),
                kind: kind,
                used: w.used_percent / 100,
                resetsAt: w.resets_at.map { Date(timeIntervalSince1970: Double($0)) },
                duration: w.window_minutes.map { Double($0) * 60 }
            ))
        }
        return LimitReading(
            provider: .codex,
            fetchedAt: timestamp,
            source: .passiveLog,
            plan: PlanCatalog.codex(planType: plan_type),
            windows: windows,
            blockedReason: rate_limit_reached_type,
            accountKey: accountKey
        )
    }
}
