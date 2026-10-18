import Foundation
import HeadroomKit

/// Parses `GET /api/oauth/usage?cedar_ember=1&skip_spend=1` (PLAN §14.1).
///
/// The generic `limits[]` array is the primary source and is classified on `kind`, never on a
/// label: `session`, `weekly_all`, `weekly_scoped`. Legacy keys (`five_hour`, `seven_day`,
/// `seven_day_opus`, `seven_day_sonnet`) fill in whatever `limits[]` lacks.
public enum ClaudeUsageParser {
    static let legacyModelKeys: [(key: String, label: String)] = [
        ("seven_day_opus", "Opus"),
        ("seven_day_sonnet", "Sonnet"),
    ]

    public static func parse(
        _ data: Data,
        fetchedAt: Date,
        plan: PlanInfo? = nil,
        accountKey: String? = nil
    ) throws(ProviderFailure) -> LimitReading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderFailure(.schemaDrift)
        }
        let limits = root["limits"] as? [[String: Any]]
        let hasLegacy = root.keys.contains("five_hour") || root.keys.contains("seven_day")
        guard limits != nil || hasLegacy else { throw ProviderFailure(.schemaDrift) }

        var windows: [LimitWindow] = []
        func has(_ id: String) -> Bool { windows.contains { $0.id == id } }

        for entry in limits ?? [] {
            guard let kind = entry["kind"] as? String else { continue }
            let used = (number(entry["percent"]) ?? 0) / 100
            let resetsAt = (entry["resets_at"] as? String).flatMap(ISODate.parse)
            let isActive = entry["is_active"] as? Bool ?? true
            switch kind {
            case "session":
                guard !has(LimitWindow.sessionID()) else { continue }
                windows.append(LimitWindow(id: LimitWindow.sessionID(), kind: .session, used: used, resetsAt: resetsAt,
                                           duration: 5 * 3600, isActive: isActive))
            case "weekly_all":
                guard !has(LimitWindow.weeklyID()) else { continue }
                windows.append(LimitWindow(id: LimitWindow.weeklyID(), kind: .weekly, used: used, resetsAt: resetsAt,
                                           duration: 7 * 86400, isActive: isActive))
            case "weekly_scoped":
                guard let name = scopeName(entry["scope"]) else { continue }
                let id = LimitWindow.modelID(name)
                guard !has(id) else { continue }
                windows.append(LimitWindow(id: id, kind: .modelWeekly, label: name, used: used, resetsAt: resetsAt,
                                           duration: 7 * 86400, isActive: isActive))
            default:
                continue
            }
        }

        if !has(LimitWindow.sessionID()), let w = legacy(root["five_hour"]) {
            windows.append(LimitWindow(id: LimitWindow.sessionID(), kind: .session, used: w.used, resetsAt: w.resetsAt,
                                       duration: 5 * 3600))
        }
        if !has(LimitWindow.weeklyID()), let w = legacy(root["seven_day"]) {
            windows.append(LimitWindow(id: LimitWindow.weeklyID(), kind: .weekly, used: w.used, resetsAt: w.resetsAt,
                                       duration: 7 * 86400))
        }
        for (key, label) in legacyModelKeys {
            let id = LimitWindow.modelID(label)
            guard !has(id), let w = legacy(root[key]) else { continue }
            windows.append(LimitWindow(id: id, kind: .modelWeekly, label: label, used: w.used, resetsAt: w.resetsAt,
                                       duration: 7 * 86400))
        }

        let credits = grants(root["cedar_ember"])
        return LimitReading(
            provider: .claude,
            fetchedAt: fetchedAt,
            source: .api,
            plan: plan,
            windows: windows,
            resetCredits: credits,
            resetCreditsAvailable: credits.isEmpty ? nil : credits.reduce(0) { $0 + $1.count },
            accountKey: accountKey
        )
    }

    static func scopeName(_ scope: Any?) -> String? {
        guard let scope = scope as? [String: Any] else { return nil }
        for key in ["model", "surface"] {
            if let inner = scope[key] as? [String: Any], let name = inner["display_name"] as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return name
            }
        }
        return nil
    }

    static func legacy(_ value: Any?) -> (used: Double, resetsAt: Date?)? {
        guard let obj = value as? [String: Any], let utilization = number(obj["utilization"]) else { return nil }
        let resetsAt: Date? = {
            if let s = obj["resets_at"] as? String { return ISODate.parse(s) }
            if let n = number(obj["resets_at"]) { return Date(timeIntervalSince1970: n) }
            return nil
        }()
        return (utilization / 100, resetsAt)
    }

    static func grants(_ value: Any?) -> [ResetCredit] {
        guard let cedar = value as? [String: Any], let grants = cedar["grants"] as? [[String: Any]] else { return [] }
        return grants.compactMap { g in
            let left = Int(number(g["resets_left"]) ?? 0)
            guard left > 0 else { return nil }
            return ResetCredit(
                expiresAt: (g["ends_at"] as? String).flatMap(ISODate.parse),
                grantedAt: (g["starts_at"] as? String).flatMap(ISODate.parse),
                title: (g["label"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                count: left
            )
        }
        .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !(n === kCFBooleanTrue || n === kCFBooleanFalse) { return n.doubleValue }
        return nil
    }
}

/// Parses the text `claude -p /usage` prints (the fallback reading, PLAN §5.1).
///
///     Current session: 51% used · resets Oct 18 at 10:10am (Asia/Calcutta)
///     Current week (all models): 18% used · resets Oct 21 at 6am (Asia/Calcutta)
///     Current week (Fable): 0% used · resets Oct 22 at 10:30pm (Asia/Calcutta)
public enum ClaudeUsageTextParser {
    public static func parse(_ text: String, now: Date, plan: PlanInfo? = nil, accountKey: String? = nil) -> LimitReading? {
        var windows: [LimitWindow] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Current "), let colon = line.firstIndex(of: ":") else { continue }
            let title = String(line[line.index(line.startIndex, offsetBy: 8)..<colon])
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let pct = rest.range(of: "% used") else { continue }
            guard let percent = Double(rest[rest.startIndex..<pct.lowerBound].trimmingCharacters(in: .whitespaces)) else { continue }
            var resetsAt: Date?
            if let r = rest.range(of: "resets ") {
                resetsAt = parseReset(String(rest[r.upperBound...]), now: now)
            }
            let used = percent / 100
            if title == "session" {
                windows.append(LimitWindow(id: LimitWindow.sessionID(), kind: .session, used: used, resetsAt: resetsAt, duration: 5 * 3600))
            } else if title.hasPrefix("week (") || title.hasPrefix("week(") {
                let inner = title.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                let name = String(inner).trimmingCharacters(in: .whitespaces)
                if name.lowercased() == "all models" {
                    windows.append(LimitWindow(id: LimitWindow.weeklyID(), kind: .weekly, used: used, resetsAt: resetsAt, duration: 7 * 86400))
                } else {
                    let label = name.lowercased().hasSuffix(" only") ? String(name.dropLast(5)) : name
                    windows.append(LimitWindow(id: LimitWindow.modelID(label), kind: .modelWeekly, label: label, used: used,
                                               resetsAt: resetsAt, duration: 7 * 86400))
                }
            } else if title == "week" {
                windows.append(LimitWindow(id: LimitWindow.weeklyID(), kind: .weekly, used: used, resetsAt: resetsAt, duration: 7 * 86400))
            }
        }
        guard !windows.isEmpty else { return nil }
        return LimitReading(provider: .claude, fetchedAt: now, source: .cliText, plan: plan, windows: windows, accountKey: accountKey)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `Oct 18 at 10:10am (Asia/Calcutta)` or `10:10am (Asia/Calcutta)`.
    static func parseReset(_ s: String, now: Date) -> Date? {
        var text = s.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let name = String(text[text.index(after: open)..<close])
            zone = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) ?? zone
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        var month: Int?
        var day: Int?
        var timePart = text
        if let at = text.range(of: " at ") {
            let datePart = text[..<at.lowerBound].split(separator: " ")
            timePart = String(text[at.upperBound...])
            if datePart.count >= 2, let m = months.firstIndex(of: String(datePart[0].prefix(3)).lowercased()), let d = Int(datePart[1]) {
                month = m + 1
                day = d
            }
        }
        let t = timePart.lowercased().replacingOccurrences(of: " ", with: "")
        let pm = t.hasSuffix("pm")
        let am = t.hasSuffix("am")
        let clock = (am || pm) ? String(t.dropLast(2)) : t
        let hm = clock.split(separator: ":")
        guard let h = Int(hm.first ?? ""), h <= 24 else { return nil }
        let minute = hm.count > 1 ? Int(hm[1]) ?? 0 : 0
        var hour = h % 12
        if pm { hour += 12 }
        if !am && !pm { hour = h }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let nowComps = cal.dateComponents([.year, .month, .day], from: now)
        var comps = DateComponents()
        comps.year = nowComps.year
        comps.month = month ?? nowComps.month
        comps.day = day ?? nowComps.day
        comps.hour = hour
        comps.minute = minute
        guard var date = cal.date(from: comps) else { return nil }
        if date < now.addingTimeInterval(-86400) {
            // A reset is always ahead: roll into the next day (time only) or the next year.
            if month == nil {
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            } else {
                comps.year = (nowComps.year ?? 0) + 1
                date = cal.date(from: comps) ?? date
            }
        } else if month == nil, date < now {
            date = cal.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
}
