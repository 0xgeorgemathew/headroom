import AppKit
import HeadroomCore
import HeadroomKit

/// History view (PLAN §7): one week's glide path in the brand color, "Week to Sep 30 · 66% used".
@MainActor
enum HistoryCardRenderer {
    static func draw(provider: Provider, record: WeekRecord?, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?,
                     calendar: Calendar = .current, locale: Locale = .current) -> CGFloat {
        let x0 = origin.x + 14, w = width - 28
        let glideH = GlideChartRenderer.height(width: w)
        let h: CGFloat = 13 + 28 + 14 + glideH + 12 + 38 * 2 + 12
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: provider, theme: theme, ctx: ctx)
        var y = origin.y + 13
        BrandMark.drawTile(provider, in: CGRect(x: x0, y: y, width: 28, height: 28), ctx: ctx)
        Text(provider.displayName, F.sf(15, 650), theme.ink, kern: -0.075).draw(x: x0 + 37, capCenter: y + 14, in: ctx)
        guard let r = record else {
            Text("This week is still running — see the Pace tab.", F.sf(12.5), theme.muted).draw(x: x0, baseline: y + 60, in: ctx)
            return h
        }
        let title = "Week to \(TimeFormat.monthDay(r.scheduledEnd, calendar: calendar, locale: locale)) · \(Int((r.finalUsed * 100).rounded()))% used"
        Text(title, F.sf(12.5, 600, tabular: true), theme.muted).draw(x: x0 + w, capCenter: y + 14, align: .right, in: ctx)
        y += 28 + 14
        let hours = max(r.scheduledEnd.timeIntervalSince(r.start) / 3600, 1)
        var points = r.samples.map { GlideModel.Point(t: $0.time.timeIntervalSince(r.start) / 3600, used: $0.used) }
        if points.first.map({ $0.t > 0.5 }) ?? true { points.insert(.init(t: 0, used: 0), at: 0) }
        let endT = r.end.timeIntervalSince(r.start) / 3600
        let glide = GlideModel(hours: hours, windowStart: r.start, nowT: min(endT, hours), points: points,
                               projectionEnd: (min(endT, hours), max(0, 1 - r.finalUsed)), runsOut: false, endLabel: nil,
                               state: .onPace, brandLine: provider)
        GlideChartRenderer.draw(glide, rect: CGRect(x: x0, y: y, width: w, height: glideH), theme: theme, ctx: ctx, calendar: calendar, locale: locale)
        y += glideH + 12
        let outcome: String = r.ranOut ? (r.hoursEarly.map { "Ran out \($0) hours early" } ?? "Ran out") : "\(Int(((1 - r.finalUsed) * 100).rounded()))% renewed unused"
        let rows = [
            DetailRowModel(icon: .ring(used: min(r.finalUsed, 1), level: r.ranOut ? .rose : .normal), label: "Outcome", value: outcome, suffix: r.earlyReset ? "reset early" : nil),
            DetailRowModel(icon: .hourglass(highlight: false), label: "5-hour limit hits", value: "\(r.sessionHits)", suffix: r.plan),
        ]
        PaceCardRenderer.drawRows(rows, rect: CGRect(x: x0, y: y, width: w, height: 76), theme: theme, ctx: ctx, out: nil)
        return h
    }
}
