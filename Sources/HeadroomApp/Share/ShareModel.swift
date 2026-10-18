import Foundation
import HeadroomKit

/// Everything a share may contain (PLAN §8). By construction it has no field for project names,
/// paths, session IDs or historical glide curves, so none can leak into a card or text block.
struct ShareModel: Equatable {
    struct Pace: Equatable {
        var state: PacingState
        var cells: Int
        var percentLeft: Int
        var period: String          // "week" / "month"
        var renewCaption: String    // "renews Wed 6:00 AM"
    }

    var provider: Provider
    var plan: String?
    var spanLong: String            // "Mon, 2 – 6 PM · 4 hours"
    var spanDuration: String        // "4 hours"
    var tokens: Int64
    var newOnly: Bool
    /// Nil when "Show cost on share cards" is off.
    var costMicros: Int64?
    var cachedShare: Double
    var newShare: Double
    var outputShare: Double
    /// Tokens per bar across the selected span (≤ 24 bars) and their labels.
    var bars: [Int64]
    var barLabels: [String]
    var barUnit: String             // "hr", "4h", "day"
    var pace: Pace?
    /// Share of the weekly allowance the span used, when known ("≈ 1% used in 4 hours").
    var allowanceUsed: Double?
}

@MainActor
enum ShareBuilder {
    /// Builds a share from an Activity card (selected span) and the provider's pace numbers.
    static func make(activity: ActivityCardModel, pace: PaceCardModel?, mode: ActivityMode, includeCost: Bool, burnInSpan: Double?, durationText: String) -> ShareModel {
        let selected = Array(activity.bars[activity.selection])
        // Merge into at most 24 bars.
        let group = max(1, Int(ceil(Double(selected.count) / 24)))
        var bars: [Int64] = []
        var labels: [String] = []
        let f = DateFormatter()
        f.locale = Display.locale
        f.calendar = Display.calendar
        f.timeZone = Display.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(selected.count > 30 ? "MMMd" : (selected.first.map { $0.end.timeIntervalSince($0.start) >= 86400 } ?? false) ? "MMMd" : "j")
        for chunk in stride(from: 0, to: selected.count, by: group) {
            let slice = selected[chunk..<min(chunk + group, selected.count)]
            bars.append(slice.reduce(0) { $0 + (mode == .all ? $1.tokens.total : $1.tokens.fresh) })
            labels.append(f.string(from: slice.first!.start).replacingOccurrences(of: "\u{202F}", with: " "))
        }
        let t = activity.totals
        let total = Double(max(1, mode == .all ? t.total : t.fresh))
        let unitSeconds = (selected.first.map { $0.end.timeIntervalSince($0.start) } ?? 3600) * Double(group)
        let unit = unitSeconds >= 86400 ? "day" : unitSeconds >= 4 * 3600 ? "\(Int(unitSeconds / 3600))h" : "hr"
        var p: ShareModel.Pace? = nil
        if let hero = pace?.hero, let meter = pace?.meter {
            p = .init(state: meter.state, cells: meter.cells, percentLeft: hero.percentLeft,
                      period: hero.label.contains("month") ? "month" : "week", renewCaption: hero.renewCaption)
        }
        return ShareModel(
            provider: activity.provider, plan: pace?.plan, spanLong: activity.spanLong, spanDuration: durationText,
            tokens: mode == .all ? t.total : t.fresh, newOnly: mode == .newOnly,
            costMicros: includeCost ? activity.micros : nil,
            cachedShare: mode == .all ? Double(t.cacheRead) / total : 0,
            newShare: Double(t.newInput + t.cacheWrite) / total, outputShare: Double(t.output) / total,
            bars: bars, barLabels: labels, barUnit: unit, pace: p, allowanceUsed: burnInSpan
        )
    }

    /// The aligned monospace text block (Copy as Text).
    static func text(_ shares: [ShareModel]) -> String {
        var lines: [String] = []
        for (i, s) in shares.enumerated() {
            if i == 0 { lines.append("Headroom · \(s.spanLong)") }
            var head = "\(NumberFormat.tokens(s.tokens)) \(s.provider.displayName)\(s.newOnly ? " new" : "") tokens"
            if let c = s.costMicros { head += " · ≈ \(NumberFormat.dollars(micros: c, style: .precise)) at API rates" }
            lines.append(head)
            lines.append(sparkline(s.bars))
            var comp: [String] = []
            if !s.newOnly { comp.append("\(NumberFormat.percent(s.cachedShare)) cached") }
            comp.append("\(NumberFormat.percent(s.newShare)) new")
            comp.append("\(NumberFormat.percent(s.outputShare)) out")
            lines.append(comp.joined(separator: " · "))
            if let used = s.allowanceUsed, let p = s.pace {
                lines.append("ate \(wholePercent(used)) of my \(p.period)")
            }
            if let p = s.pace {
                let cells = (0..<5).map { $0 < p.cells ? p.state.emojiCell : PacingState.emptyEmojiCell }.joined()
                lines.append("\(cells) \(p.percentLeft)% of \(p.period) left")
            }
            if i < shares.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    /// "1%", or "<1%" for a sliver.
    static func wholePercent(_ f: Double) -> String {
        f > 0 && f < 0.005 ? "<1%" : "\(Int((f * 100).rounded()))%"
    }

    static func sparkline(_ values: [Int64]) -> String {
        let ticks = Array("▁▂▃▄▅▆▇█")
        guard let maxV = values.max(), maxV > 0 else { return String(repeating: "▁", count: max(values.count, 1)) }
        return String(values.map { v in
            v <= 0 ? ticks[0] : ticks[min(ticks.count - 1, Int((Double(v) / Double(maxV) * Double(ticks.count - 1)).rounded()))]
        })
    }
}
