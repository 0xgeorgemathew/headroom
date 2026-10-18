import Foundation
import HeadroomKit

/// One hour of usage for one provider/model/project, as stored by the bucket store.
struct HourAggregate: Sendable, Hashable {
    var provider: Provider
    var hour: Date
    var model: String
    var project: String?
    var tokens: TokenCounts
    var micros: Int64
    var priced: Bool
    /// Micro-dollars by token class: input, cache write, cache read, output.
    var classMicros: [Int64] = []
}

/// Builds Activity cards from hourly aggregates for a range and a selection.
@MainActor
struct ActivityPresenter {
    var now: Date
    var calendar: Calendar = .current
    var locale: Locale = .current
    var pricing: PricingEngine?

    struct Bins {
        var starts: [Date]
        var step: (Date) -> Date
        var labels: [(Int, String)]
    }

    func bins(for range: ActivityRange) -> Bins {
        switch range {
        case .day:
            let current = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let starts = (0..<24).map { current.addingTimeInterval(Double($0 - 23) * 3600) }
            let labels = stride(from: 0, to: 24, by: 6).map { ($0, hourLabel(starts[$0])) }
            return Bins(starts: starts, step: { $0.addingTimeInterval(3600) }, labels: labels)
        case .week:
            let dayStart = calendar.startOfDay(for: now)
            let block = Int(now.timeIntervalSince(dayStart) / (4 * 3600))
            let current = dayStart.addingTimeInterval(Double(block) * 4 * 3600)
            let starts = (0..<42).map { current.addingTimeInterval(Double($0 - 41) * 4 * 3600) }
            let labels = starts.enumerated().compactMap { i, d -> (Int, String)? in
                calendar.component(.hour, from: d) == 0 && i < 40 ? (i, weekday(d)) : nil
            }
            return Bins(starts: starts, step: { $0.addingTimeInterval(4 * 3600) }, labels: labels)
        case .month:
            let today = calendar.startOfDay(for: now)
            let starts = (0..<30).compactMap { calendar.date(byAdding: .day, value: $0 - 29, to: today) }
            let labels = stride(from: 1, to: 30, by: 7).map { ($0, monthDay(starts[$0])) }
            return Bins(starts: starts, step: { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0.addingTimeInterval(86400) }, labels: labels)
        }
    }

    func card(_ provider: Provider, aggregates: [HourAggregate], range: ActivityRange, selection: Range<Int>?) -> ActivityCardModel {
        let b = bins(for: range)
        let n = b.starts.count
        let sel = (selection ?? 0..<n).clamped(to: 0..<n)
        var bars = b.starts.map { ActivityBar(start: $0, end: b.step($0), tokens: .zero, micros: 0) }
        let mine = aggregates.filter { $0.provider == provider }
        guard let first = b.starts.first else {
            return ActivityCardModel(provider: provider, bars: [], selection: 0..<0, axisLabels: [], spanLabel: "", spanLong: "", totals: .zero, micros: 0, breakdown: [:], footnote: nil)
        }
        var inSelection: [HourAggregate] = []
        for a in mine where a.hour >= first {
            // Binary search would be faster; n ≤ 42 so a scan is fine.
            guard let i = b.starts.lastIndex(where: { $0 <= a.hour }), a.hour < bars[i].end else { continue }
            bars[i].tokens += a.tokens
            bars[i].micros += a.micros
            if sel.contains(i) { inSelection.append(a) }
        }
        let totals = inSelection.reduce(TokenCounts.zero) { $0 + $1.tokens }
        let micros = inSelection.reduce(Int64(0)) { $0 + $1.micros }
        let spanStart = bars[sel.lowerBound].start
        let spanEnd = min(bars[max(sel.upperBound - 1, sel.lowerBound)].end, max(now, spanStart))
        let whole = sel.count == n
        let (short, long) = whole ? rangeLabel(range) : spanLabels(spanStart, spanEnd, range: range)

        var breakdown: [BreakdownKind: [BreakdownRow]] = [:]
        breakdown[.model] = rows(group(inSelection, key: { displayModel($0.model) }), total: micros)
        breakdown[.project] = rows(group(inSelection, key: { $0.project ?? "Other" }), total: micros)
        breakdown[.tokenClass] = classRows(inSelection, total: micros)

        var footnote: String? = nil
        if let pricing {
            var byModel: [String: Int64] = [:]
            for a in inSelection { byModel[a.model, default: 0] += a.tokens.total }
            let summary = UnpricedSummary(tokensByModel: byModel, engine: pricing)
            if summary.share > 0 { footnote = summary.footnote }
        }
        return ActivityCardModel(provider: provider, bars: bars, selection: sel, axisLabels: b.labels.map { (index: $0.0, text: $0.1) },
                                 spanLabel: short, spanLong: long, totals: totals, micros: micros, breakdown: breakdown, footnote: footnote)
    }

    // MARK: Breakdown

    private func group(_ items: [HourAggregate], key: (HourAggregate) -> String) -> [(String, Int64)] {
        var m: [String: Int64] = [:]
        for a in items { m[key(a), default: 0] += a.micros }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func rows(_ groups: [(String, Int64)], total: Int64) -> [BreakdownRow] {
        let t = max(Double(total), 1)
        var head = Array(groups.prefix(5))
        let rest = groups.dropFirst(5).reduce(Int64(0)) { $0 + $1.1 }
        if rest > 0 { head.append(("Other", rest)) }
        return head.filter { $0.1 > 0 }.map { BreakdownRow(name: $0.0, micros: $0.1, share: Double($0.1) / t) }
    }

    private func classRows(_ items: [HourAggregate], total: Int64) -> [BreakdownRow] {
        var input: Double = 0, write: Double = 0, read: Double = 0, output: Double = 0
        for a in items where a.micros > 0 {
            if a.classMicros.count == 4 {
                input += Double(a.classMicros[0]); write += Double(a.classMicros[1])
                read += Double(a.classMicros[2]); output += Double(a.classMicros[3])
                continue
            }
            guard let c = pricing?.price(tokens: a.tokens, model: a.model), c.micros > 0 else { continue }
            let scale = Double(a.micros) / Double(c.micros)
            input += Double(c.input) * scale; write += Double(c.cacheWrite) * scale
            read += Double(c.cacheRead) * scale; output += Double(c.output) * scale
        }
        let t = max(Double(total), 1)
        return [("Input", input), ("Cache write", write), ("Cache read", read), ("Output", output)]
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { BreakdownRow(name: $0.0, micros: Int64($0.1.rounded()), share: $0.1 / t) }
    }

    /// "claude-opus-5-5" → "Opus 5.5"; other providers keep their IDs.
    func displayModel(_ raw: String) -> String {
        let id = ModelID.normalize(raw)
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    // MARK: Labels

    private func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private func clean(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
    func hourLabel(_ d: Date) -> String { clean(formatter("j").string(from: d)) }
    func weekday(_ d: Date) -> String { formatter("EEE").string(from: d).uppercased() }
    func monthDay(_ d: Date) -> String { formatter("MMMd").string(from: d) }

    private func rangeLabel(_ r: ActivityRange) -> (String, String) {
        switch r {
        case .day: ("Last 24h", "Last 24 hours")
        case .week: ("Last 7d", "Last 7 days")
        case .month: ("Last 30d", "Last 30 days")
        }
    }

    /// "Mon 2 – 6 PM · 4h" / "Mon, 2 – 6 PM · 4 hours".
    func spanLabels(_ a: Date, _ b: Date, range: ActivityRange) -> (String, String) {
        let dur = b.timeIntervalSince(a)
        let durShort = TimeFormat.compact(dur)
        let durLong = TimeFormat.spokenSpan(dur)
        if range == .month {
            let s = "\(monthDay(a)) – \(monthDay(b.addingTimeInterval(-1)))"
            return ("\(s) · \(durShort)", "\(s) · \(durLong)")
        }
        let sameDay = calendar.isDate(a, inSameDayAs: b.addingTimeInterval(-1))
        let wd = formatter("EEE").string(from: a)
        let hA = clean(formatter("j").string(from: a)), hB = clean(formatter("j").string(from: b))
        let periodA = hA.components(separatedBy: " ").last, periodB = hB.components(separatedBy: " ").last
        let startText = sameDay && periodA == periodB ? (hA.components(separatedBy: " ").first ?? hA) : hA
        if sameDay {
            return ("\(wd) \(startText) – \(hB) · \(durShort)", "\(wd), \(startText) – \(hB) · \(durLong)")
        }
        let wdB = formatter("EEE").string(from: b)
        return ("\(wd) \(hA) – \(wdB) \(hB) · \(durShort)", "\(wd) \(hA) – \(wdB) \(hB) · \(durLong)")
    }
}
