import Foundation

/// `snapshot.json`, schema 1 (PLAN §9): what the app knows, written atomically for the CLI,
/// status lines, `wait` and MCP. No credentials, account IDs, project names or paths.
public struct Snapshot: Codable, Sendable, Hashable {
    public static let currentSchema = 1

    public var schema: Int
    public var generatedAt: Date
    public var appVersion: String
    /// PID of the writing app, so readers can tell a live snapshot from a stale one.
    public var appPID: Int32
    public var providers: [ProviderSnapshot]

    public init(generatedAt: Date, appVersion: String, appPID: Int32, providers: [ProviderSnapshot]) {
        self.schema = Self.currentSchema
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appPID = appPID
        self.providers = providers
    }

    public func provider(_ p: Provider) -> ProviderSnapshot? { providers.first { $0.id == p } }

    enum CodingKeys: String, CodingKey {
        case schema, providers
        case generatedAt = "generated_at"
        case appVersion = "app_version"
        case appPID = "app_pid"
    }
}

public struct ProviderSnapshot: Codable, Sendable, Hashable {
    public var id: Provider
    public var plan: String?
    public var readingAt: Date?
    public var source: String?
    public var fault: FaultSnapshot?
    public var weekly: WeeklySnapshot?
    public var session: SessionSnapshot?
    public var caps: [CapSnapshot]
    public var credits: CreditsSnapshot?
    public var blocked: BlockedSnapshot?
    public var activity24h: ActivitySnapshot?
    public var weekCostUSD: Double?
    public var planMultiple: Double?

    public init(id: Provider, plan: String? = nil, readingAt: Date? = nil, source: String? = nil, fault: FaultSnapshot? = nil,
                weekly: WeeklySnapshot? = nil, session: SessionSnapshot? = nil, caps: [CapSnapshot] = [], credits: CreditsSnapshot? = nil,
                blocked: BlockedSnapshot? = nil, activity24h: ActivitySnapshot? = nil, weekCostUSD: Double? = nil, planMultiple: Double? = nil) {
        self.id = id; self.plan = plan; self.readingAt = readingAt; self.source = source; self.fault = fault
        self.weekly = weekly; self.session = session; self.caps = caps; self.credits = credits; self.blocked = blocked
        self.activity24h = activity24h; self.weekCostUSD = weekCostUSD; self.planMultiple = planMultiple
    }

    enum CodingKeys: String, CodingKey {
        case id, plan, source, fault, weekly, session, caps, credits, blocked
        case readingAt = "reading_at"
        case activity24h = "activity_24h"
        case weekCostUSD = "week_cost_usd"
        case planMultiple = "plan_multiple"
    }
}

public struct FaultSnapshot: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct WeeklySnapshot: Codable, Sendable, Hashable {
    /// Model name when the headline is a model-scoped cap (plans without an all-models weekly limit).
    public var label: String?
    public var used: Double
    public var left: Double
    public var resetsAt: Date
    public var windowHours: Double
    public var state: String
    /// Sustainable multiple S; nil when infinite (last hour with allowance left).
    public var multiple: Double?
    public var cells: Int
    public var hourglass: Bool
    public var runsOutAt: Date?
    public var unusedAtReset: Double?
    public var verdict: VerdictSnapshot

    public init(label: String?, used: Double, left: Double, resetsAt: Date, windowHours: Double, state: String, multiple: Double?,
                cells: Int, hourglass: Bool, runsOutAt: Date?, unusedAtReset: Double?, verdict: VerdictSnapshot) {
        self.label = label; self.used = used; self.left = left; self.resetsAt = resetsAt; self.windowHours = windowHours
        self.state = state; self.multiple = multiple; self.cells = cells; self.hourglass = hourglass
        self.runsOutAt = runsOutAt; self.unusedAtReset = unusedAtReset; self.verdict = verdict
    }

    public var pacingState: PacingState {
        switch state {
        case "plenty": .plenty
        case "tight": .tight
        case "very_tight": .veryTight
        default: .onPace
        }
    }

    public static func stateCode(_ s: PacingState) -> String {
        switch s {
        case .plenty: "plenty"
        case .onPace: "on_pace"
        case .tight: "tight"
        case .veryTight: "very_tight"
        }
    }

    enum CodingKeys: String, CodingKey {
        case label, used, left, state, multiple, cells, hourglass, verdict
        case resetsAt = "resets_at"
        case windowHours = "window_hours"
        case runsOutAt = "runs_out_at"
        case unusedAtReset = "unused_at_reset"
    }
}

public struct VerdictSnapshot: Codable, Sendable, Hashable {
    public var title: String
    public var primary: String
    public var secondary: String
    public init(title: String, primary: String, secondary: String) { self.title = title; self.primary = primary; self.secondary = secondary }
}

public struct SessionSnapshot: Codable, Sendable, Hashable {
    public var used: Double
    public var left: Double
    public var resetsAt: Date?
    /// normal · amber · rose · blocked
    public var level: String
    /// idle · comfortable · lasts · runs_out · blocked (absent in snapshots from older apps).
    public var outlook: String?
    /// When the session runs out at the recent burn, if before its reset.
    public var runsOutAt: Date?
    /// Share left at the reset at the recent burn.
    public var leftAtReset: Double?
    public init(used: Double, left: Double, resetsAt: Date?, level: String, outlook: String? = nil, runsOutAt: Date? = nil, leftAtReset: Double? = nil) {
        self.used = used; self.left = left; self.resetsAt = resetsAt; self.level = level
        self.outlook = outlook; self.runsOutAt = runsOutAt; self.leftAtReset = leftAtReset
    }

    public var sessionLevel: SessionLevel {
        switch level { case "amber": .amber; case "rose": .rose; case "blocked": .blocked; default: .normal }
    }

    public static func levelCode(_ l: SessionLevel) -> String {
        switch l { case .normal: "normal"; case .amber: "amber"; case .rose: "rose"; case .blocked: "blocked" }
    }

    public static func outlookCode(_ o: SessionForecast.Outlook) -> String {
        switch o { case .idle: "idle"; case .comfortable: "comfortable"; case .lasts: "lasts"; case .runsOut: "runs_out"; case .blocked: "blocked" }
    }

    enum CodingKeys: String, CodingKey {
        case used, left, level, outlook
        case resetsAt = "resets_at"
        case runsOutAt = "runs_out_at"
        case leftAtReset = "left_at_reset"
    }
}

public struct CapSnapshot: Codable, Sendable, Hashable {
    public var label: String
    public var used: Double
    public var resetsAt: Date?
    public var active: Bool
    public init(label: String, used: Double, resetsAt: Date?, active: Bool) { self.label = label; self.used = used; self.resetsAt = resetsAt; self.active = active }
    enum CodingKeys: String, CodingKey {
        case label, used, active
        case resetsAt = "resets_at"
    }
}

public struct CreditsSnapshot: Codable, Sendable, Hashable {
    public var available: Int
    public var nextExpiry: Date?
    /// Credits expiring within 7 days.
    public var expiringSoon: Int
    public init(available: Int, nextExpiry: Date?, expiringSoon: Int) { self.available = available; self.nextExpiry = nextExpiry; self.expiringSoon = expiringSoon }
    enum CodingKeys: String, CodingKey {
        case available
        case nextExpiry = "next_expiry"
        case expiringSoon = "expiring_soon"
    }
}

public struct BlockedSnapshot: Codable, Sendable, Hashable {
    /// `session` · `weekly` · `model_cap` · `outage`
    public var by: String
    public var detail: String?
    public var until: Date?
    public init(by: String, detail: String?, until: Date?) { self.by = by; self.detail = detail; self.until = until }
}

public struct ActivitySnapshot: Codable, Sendable, Hashable {
    public var tokens: Int64
    public var newTokens: Int64
    public var costUSD: Double
    public init(tokens: Int64, newTokens: Int64, costUSD: Double) { self.tokens = tokens; self.newTokens = newTokens; self.costUSD = costUSD }
    enum CodingKeys: String, CodingKey {
        case tokens
        case newTokens = "new_tokens"
        case costUSD = "cost_usd"
    }
}

// MARK: - Location, coding, refresh signal

public enum SnapshotFile {
    /// `~/Library/Application Support/Headroom/`
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("snapshot.json") }

    /// Darwin notification the CLI posts to ask the app for fresh limits.
    public static let refreshNotification = "com.headroom.refresh"

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.headroom.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.headroom.string(from: date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func read(from url: URL = url) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(Snapshot.self, from: data)
    }

    /// Whether the app that wrote the snapshot is still running.
    public static func writerIsAlive(_ s: Snapshot) -> Bool {
        s.appPID > 0 && kill(s.appPID, 0) == 0
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) public static let headroom: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
