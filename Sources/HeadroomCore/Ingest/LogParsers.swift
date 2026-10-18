import Foundation
import HeadroomKit

/// Byte-pattern helpers shared by the parsers.
enum Bytes {
    @inline(__always) static func contains(_ p: UnsafePointer<UInt8>, _ n: Int, _ needle: StaticString) -> Bool {
        memmem(p, n, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    static func lastPathComponent(_ path: String) -> String? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed.isEmpty ? nil : trimmed }
        let name = String(trimmed[trimmed.index(after: slash)...])
        return name.isEmpty ? nil : name
    }
}

// MARK: - Claude Code

/// Parses `~/.claude/projects/**/*.jsonl` assistant lines (PLAN §5.3, §14.3).
enum ClaudeLogParser {
    /// Returns the usage event on an assistant line, or nil for any other line.
    /// `fallbackKey` identifies keyless lines (their byte offset in the file).
    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, fallbackKey: @autoclosure () -> String) -> UsageEvent? {
        guard Bytes.contains(p, n, "\"usage\":{"), Bytes.contains(p, n, "\"type\":\"assistant\"") else { return nil }
        let s = JSONScan(p, n)
        var isAssistant = false
        var model: String?
        var messageID: String?
        var requestID: String?
        var timestamp: Double?
        var cwd: String?
        var usage: ByteSpan?
        let ok = s.forEachMember(0) { key, value in
            if s.key(key, is: "message") {
                s.forEachMember(value.start) { k, v in
                    if s.key(k, is: "model") { model = s.string(v) }
                    else if s.key(k, is: "id") { messageID = s.string(v) }
                    else if s.key(k, is: "usage") { usage = v }
                    return true
                }
            } else if s.key(key, is: "type") {
                if let raw = s.rawString(value) {
                    isAssistant = raw.count == 9 && memcmp(raw.baseAddress!, "assistant", 9) == 0
                }
            } else if s.key(key, is: "requestId") {
                requestID = s.string(value)
            } else if s.key(key, is: "timestamp") {
                timestamp = s.rawString(value).flatMap(FastTimestamp.parse)
            } else if s.key(key, is: "cwd") {
                cwd = s.string(value)
            }
            return true
        }
        guard ok, isAssistant, let usage, let timestamp else { return nil }
        guard let parsed = parseUsage(s, usage) else { return nil }
        let tokens = parsed.tokens
        guard tokens.total > 0 else { return nil }
        let key: String
        if let messageID {
            key = requestID.map { messageID + ":" + $0 } ?? messageID
        } else {
            key = fallbackKey()
        }
        return UsageEvent(
            provider: .claude,
            timestamp: Date(timeIntervalSince1970: timestamp),
            model: model ?? "unknown",
            project: cwd.flatMap(Bytes.lastPathComponent),
            tokens: tokens,
            speed: parsed.speed,
            dedupeKey: key
        )
    }

    static func parseUsage(_ s: JSONScan, _ span: ByteSpan) -> (tokens: TokenCounts, speed: Speed)? {
        var input: Int64 = 0, creation: Int64 = 0, read: Int64 = 0, output: Int64 = 0
        var e5m: Int64?, e1h: Int64?
        var speed = Speed.standard
        let ok = s.forEachMember(span.start) { k, v in
            if s.key(k, is: "input_tokens") { input = s.int(v) ?? 0 }
            else if s.key(k, is: "cache_creation_input_tokens") { creation = s.int(v) ?? 0 }
            else if s.key(k, is: "cache_read_input_tokens") { read = s.int(v) ?? 0 }
            else if s.key(k, is: "output_tokens") { output = s.int(v) ?? 0 }
            else if s.key(k, is: "speed") {
                if let raw = s.rawString(v), raw.count == 4, memcmp(raw.baseAddress!, "fast", 4) == 0 { speed = .fast }
            } else if s.key(k, is: "cache_creation") {
                s.forEachMember(v.start) { k2, v2 in
                    if s.key(k2, is: "ephemeral_5m_input_tokens") { e5m = s.int(v2) }
                    else if s.key(k2, is: "ephemeral_1h_input_tokens") { e1h = s.int(v2) }
                    return true
                }
            }
            return true
        }
        guard ok else { return nil }
        var w5 = creation, w1 = Int64(0)
        if e5m != nil || e1h != nil {
            w1 = max(e1h ?? 0, 0)
            w5 = max(e5m ?? 0, 0)
            // Any creation tokens the split doesn't account for are treated as 5-minute writes.
            if w5 + w1 < creation { w5 = creation - w1 }
        }
        return (TokenCounts(newInput: max(input, 0), cacheWrite5m: max(w5, 0), cacheWrite1h: w1,
                            cacheRead: max(read, 0), output: max(output, 0)), speed)
    }
}

// MARK: - Codex

/// Passive `rate_limits` from a Codex `token_count` event (snake_case, PLAN §14.3).
/// Only readings from sessions on the built-in `openai` provider are trusted for limits.
public struct PassiveCodexLimits: Codable, Sendable, Hashable {
    public struct Window: Codable, Sendable, Hashable {
        public var usedPercent: Double
        public var windowMinutes: Int?
        public var resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    public var timestamp: Date
    public var providerIsOpenAI: Bool
    public var limitID: String?
    public var primary: Window?
    public var secondary: Window?
    public var planType: String?
    public var rateLimitReachedType: String?
    public var hasCredits: Bool?
    public var unlimitedCredits: Bool?
    public var creditBalance: String?

    public init(timestamp: Date, providerIsOpenAI: Bool, limitID: String? = nil, primary: Window? = nil,
                secondary: Window? = nil, planType: String? = nil, rateLimitReachedType: String? = nil,
                hasCredits: Bool? = nil, unlimitedCredits: Bool? = nil, creditBalance: String? = nil) {
        self.timestamp = timestamp
        self.providerIsOpenAI = providerIsOpenAI
        self.limitID = limitID
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.hasCredits = hasCredits
        self.unlimitedCredits = unlimitedCredits
        self.creditBalance = creditBalance
    }
}

/// Per-file state the Codex parser carries between appends. Persisted with the cursor.
public struct CodexFileState: Codable, Sendable, Hashable {
    public var model: String?
    public var project: String?
    public var provider: String?
    /// A `token_usage_record` has been seen: `token_count` usage is ignored from then on.
    public var sawRecord = false
    /// Legacy events emitted before the first record, retracted if a record appears.
    public var legacyKeys: [String] = []
    /// Last `total_token_usage` (input, cached, output) to skip unchanged legacy events.
    public var lastTotal: [Int64]?
    public var legacyCount = 0

    public init() {}
}

/// What one Codex line contributed.
enum CodexLine {
    case none
    case event(UsageEvent)
    /// First record in a file that had already produced legacy events: retract those keys, then add.
    case eventRetracting(UsageEvent, [String])
    case limits(PassiveCodexLimits)
    /// Legacy token_count: an event and the passive limits it carried.
    case legacy(UsageEvent?, PassiveCodexLimits?)
}

/// Parses `~/.codex/sessions/**/rollout-*.jsonl` lines (PLAN §5.3, §14.3).
enum CodexLogParser {
    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, state: inout CodexFileState, fileKey: String) -> CodexLine {
        // Cheap rejection of the large response_item lines.
        let head = min(n, 160)
        let isRecord = Bytes.contains(p, head, "\"type\":\"token_usage_record\"")
        let isEvent = !isRecord && Bytes.contains(p, head, "\"type\":\"event_msg\"")
        let isMeta = !isRecord && !isEvent && Bytes.contains(p, head, "\"type\":\"session_meta\"")
        let isTurn = !isRecord && !isEvent && !isMeta && Bytes.contains(p, head, "\"type\":\"turn_context\"")
        guard isRecord || isEvent || isMeta || isTurn else { return .none }
        if isEvent && !Bytes.contains(p, n, "\"token_count\"") { return .none }

        let s = JSONScan(p, n)
        var timestamp: Double?
        var payload: ByteSpan?
        s.forEachMember(0) { k, v in
            if s.key(k, is: "timestamp") { timestamp = s.rawString(v).flatMap(FastTimestamp.parse) }
            else if s.key(k, is: "payload") { payload = v }
            return true
        }
        guard let payload else { return .none }

        if isMeta {
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "cwd") { state.project = s.string(v).flatMap(Bytes.lastPathComponent) }
                else if s.key(k, is: "model_provider") { state.provider = s.string(v) }
                return true
            }
            return .none
        }
        if isTurn {
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "model"), let m = s.string(v) { state.model = m }
                return true
            }
            return .none
        }
        guard let timestamp else { return .none }
        let date = Date(timeIntervalSince1970: timestamp)

        if isRecord {
            var responseID: String?
            var usage: ByteSpan?
            s.forEachMember(payload.start) { k, v in
                if s.key(k, is: "response_id") { responseID = s.string(v) }
                else if s.key(k, is: "usage") { usage = v }
                return true
            }
            guard let usage, let tokens = codexTokens(s, usage) else { return .none }
            let key = responseID.map { "R:" + $0 } ?? "R@\(fileKey):\(timestamp)"
            let event = UsageEvent(provider: .codex, timestamp: date, model: state.model ?? "unknown",
                                   project: state.project, tokens: tokens, speed: .standard, dedupeKey: key)
            if !state.sawRecord {
                state.sawRecord = true
                let retract = state.legacyKeys
                state.legacyKeys = []
                if !retract.isEmpty { return .eventRetracting(event, retract) }
            }
            return .event(event)
        }

        // event_msg / token_count
        var isTokenCount = false
        var info: ByteSpan?
        var limitsSpan: ByteSpan?
        s.forEachMember(payload.start) { k, v in
            if s.key(k, is: "type") {
                if let raw = s.rawString(v) { isTokenCount = raw.count == 11 && memcmp(raw.baseAddress!, "token_count", 11) == 0 }
            } else if s.key(k, is: "info") { info = s.isNull(v) ? nil : v }
            else if s.key(k, is: "rate_limits") { limitsSpan = s.isNull(v) ? nil : v }
            return true
        }
        guard isTokenCount else { return .none }
        let limits = limitsSpan.flatMap { passiveLimits(s, $0, date: date, providerIsOpenAI: state.provider == "openai") }

        var event: UsageEvent?
        if !state.sawRecord, let info {
            var last: ByteSpan?, total: ByteSpan?
            s.forEachMember(info.start) { k, v in
                if s.key(k, is: "last_token_usage") { last = v }
                else if s.key(k, is: "total_token_usage") { total = v }
                return true
            }
            let totalKey = total.flatMap { codexTotals(s, $0) }
            if let totalKey, totalKey == state.lastTotal {
                // Unchanged totals: a rate-limit-only update.
            } else if let last, let tokens = codexTokens(s, last), tokens.total > 0 {
                state.legacyCount += 1
                let key = "L:\(fileKey)#\(state.legacyCount)"
                state.legacyKeys.append(key)
                event = UsageEvent(provider: .codex, timestamp: date, model: state.model ?? "unknown",
                                   project: state.project, tokens: tokens, speed: .standard, dedupeKey: key)
            }
            if let totalKey { state.lastTotal = totalKey }
        }
        if event == nil, let limits { return .limits(limits) }
        return .legacy(event, limits)
    }

    static func codexTokens(_ s: JSONScan, _ span: ByteSpan) -> TokenCounts? {
        var input: Int64 = 0, cached: Int64 = 0, write: Int64 = 0, output: Int64 = 0
        let ok = s.forEachMember(span.start) { k, v in
            if s.key(k, is: "input_tokens") { input = s.int(v) ?? 0 }
            else if s.key(k, is: "cached_input_tokens") { cached = s.int(v) ?? 0 }
            else if s.key(k, is: "cache_write_input_tokens") { write = s.int(v) ?? 0 }
            else if s.key(k, is: "output_tokens") { output = s.int(v) ?? 0 }
            return true
        }
        guard ok else { return nil }
        return TokenCounts(newInput: max(input - cached - write, 0), cacheWrite5m: max(write, 0),
                           cacheRead: max(cached, 0), output: max(output, 0))
    }

    static func codexTotals(_ s: JSONScan, _ span: ByteSpan) -> [Int64]? {
        var input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, total: Int64 = 0
        let ok = s.forEachMember(span.start) { k, v in
            if s.key(k, is: "input_tokens") { input = s.int(v) ?? 0 }
            else if s.key(k, is: "cached_input_tokens") { cached = s.int(v) ?? 0 }
            else if s.key(k, is: "output_tokens") { output = s.int(v) ?? 0 }
            else if s.key(k, is: "total_tokens") { total = s.int(v) ?? 0 }
            return true
        }
        return ok ? [input, cached, output, total] : nil
    }

    static func passiveLimits(_ s: JSONScan, _ span: ByteSpan, date: Date, providerIsOpenAI: Bool) -> PassiveCodexLimits? {
        var out = PassiveCodexLimits(timestamp: date, providerIsOpenAI: providerIsOpenAI)
        func window(_ v: ByteSpan) -> PassiveCodexLimits.Window? {
            if s.isNull(v) { return nil }
            var used: Double?, minutes: Int?, resets: Date?
            s.forEachMember(v.start) { k, x in
                if s.key(k, is: "used_percent") { used = s.double(x) }
                else if s.key(k, is: "window_minutes") { minutes = s.int(x).map(Int.init) }
                else if s.key(k, is: "resets_at") { resets = s.int(x).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
                return true
            }
            return used.map { PassiveCodexLimits.Window(usedPercent: $0, windowMinutes: minutes, resetsAt: resets) }
        }
        let ok = s.forEachMember(span.start) { k, v in
            if s.key(k, is: "limit_id") { out.limitID = s.string(v) }
            else if s.key(k, is: "primary") { out.primary = window(v) }
            else if s.key(k, is: "secondary") { out.secondary = window(v) }
            else if s.key(k, is: "plan_type") { out.planType = s.string(v) }
            else if s.key(k, is: "rate_limit_reached_type") { out.rateLimitReachedType = s.string(v) }
            else if s.key(k, is: "credits"), !s.isNull(v) {
                s.forEachMember(v.start) { k2, v2 in
                    if s.key(k2, is: "has_credits") { out.hasCredits = s.bool(v2) }
                    else if s.key(k2, is: "unlimited") { out.unlimitedCredits = s.bool(v2) }
                    else if s.key(k2, is: "balance") { out.creditBalance = s.string(v2) }
                    return true
                }
            }
            return true
        }
        return ok ? out : nil
    }
}

extension PassiveCodexLimits {
    /// The log-carried limits as a reading. Only `openai`-provider sessions are trusted
    /// (PLAN §5.2); custom-provider sessions return nil.
    public func reading(accountKey: String?) -> LimitReading? {
        guard providerIsOpenAI else { return nil }
        func window(_ w: Window?) -> CodexPassiveRateLimits.Window? {
            w.map { .init(used_percent: $0.usedPercent, window_minutes: $0.windowMinutes, resets_at: $0.resetsAt.map { Int($0.timeIntervalSince1970) }) }
        }
        let raw = CodexPassiveRateLimits(limit_id: limitID, primary: window(primary), secondary: window(secondary),
                                         plan_type: planType, rate_limit_reached_type: rateLimitReachedType)
        return raw.reading(at: timestamp, accountKey: accountKey)
    }
}
