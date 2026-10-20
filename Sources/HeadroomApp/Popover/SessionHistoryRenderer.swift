import AppKit
import HeadroomCore
import HeadroomKit

/// 5-hour sessions: the peak of each recent session, so a run of near-misses is easy to spot.
@MainActor
enum SessionHistoryRenderer {
    static let sectionHeaderHeight: CGFloat = 30
    static let maxBars = 18

    static func drawSectionHeader(x: CGFloat, y: CGFloat, width: CGFloat, warnAt: Double, theme: Theme, ctx: CGContext) {
        let mid = y + 14
        Text("5-hour sessions", F.sf(15, 650), theme.ink, kern: -0.15).draw(x: x + 3, capCenter: mid, in: ctx)
        let right = Text("peak of each · warns at \(Int((warnAt * 100).rounded()))%", F.sf(11.5, 500), theme.muted)
        right.draw(x: x + width - 3, capCenter: mid, align: .right, in: ctx)
        // The dashed key for the warning line.
        let kx = x + width - 3 - right.width - 6 - 12
        let key = CGMutablePath(); key.move(to: CGPoint(x: kx, y: mid)); key.addLine(to: CGPoint(x: kx + 12, y: mid))
        ctx.stroke(key, theme.amber.fade(0.7), width: 1, dash: [2, 2])
    }

    /// Builds the card model from stored sessions (newest last).
    static func model(_ p: Provider, sessions: [SessionRecord], warnAt: Double, now: Date,
                      calendar: Calendar = Display.calendar, locale: Locale = Display.locale) -> SessionHistoryModel {
        let shown = Array(sessions.suffix(maxBars))
        var lastDay: Int?
        let bars = shown.map { s -> SessionBar in
            let day = calendar.ordinality(of: .day, in: .era, for: s.start)
            let label = day != lastDay ? TimeFormat.weekdayShort(s.start, calendar: calendar, locale: locale).uppercased() : nil
            lastDay = day
            let span = TimeFormat.shortDayTime(s.start, now: now, calendar: calendar, locale: locale) + " – " + TimeFormat.shortClock(s.resetsAt, calendar: calendar, locale: locale)
            var tip = "\(span) · peak \(Int((s.peakUsed * 100).rounded()))%"
            if let short = s.cutShort, s.hitLimit { tip += " · hit the limit \(Presenter.hoursMinutes(short)) before the reset" }
            if s.inProgress { tip = "Running now · \(Int((s.peakUsed * 100).rounded()))% used so far" }
            return SessionBar(peak: min(max(s.peakUsed, 0), 1), hitLimit: s.hitLimit, inProgress: s.inProgress, dayLabel: label, tooltip: tip)
        }
        let week = sessions.filter { !$0.inProgress && $0.start > now.addingTimeInterval(-7 * 86400) }
        var chips: [(color: PastWeeksModel.ChipDot, text: String)] = []
        if !week.isEmpty {
            let hits = week.filter(\.hitLimit).count
            chips.append((.rose, "\(hits) of \(week.count) hit the limit"))
            let avg = week.map(\.peakUsed).reduce(0, +) / Double(week.count)
            chips.append((.azure, "\(Int((avg * 100).rounded()))% avg peak"))
        }
        return SessionHistoryModel(provider: p, bars: bars, warnAt: warnAt, chips: chips)
    }

    @discardableResult
    static func draw(_ m: SessionHistoryModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let barsH: CGFloat = 58
        let h: CGFloat = m.bars.isEmpty ? 13 + 20 + 12 + 40 + 12 : 13 + 20 + 14 + barsH + 6 + 10 + 12
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: m.provider, theme: theme, ctx: ctx)
        let x0 = origin.x + 14, w = width - 28
        var y = origin.y + 13
        BrandMark.drawTile(m.provider, in: CGRect(x: x0, y: y, width: 20, height: 20), ctx: ctx)
        Text(m.provider.displayName, F.sf(14, 650), theme.ink, kern: -0.07).draw(x: x0 + 20 + 8, capCenter: y + 10, in: ctx)
        var cx = x0 + w
        for chip in m.chips.reversed() {
            let t = Text(chip.text, F.sf(10.5, 600, tabular: true), theme.ink)
            let cw = 7 + 6 + 5 + t.width + 7
            let r = CGRect(x: cx - cw, y: y + 10 - 9, width: cw, height: 18)
            ctx.fill(rounded(r, 7), theme.chipFill)
            ctx.innerStroke(rounded(r, 7), theme.chipBorder, width: 0.5)
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: r.minX + 7, y: r.midY - 3, width: 6, height: 6))
            ctx.fill(dot, chip.color == .rose ? theme.rose : theme.azure)
            t.draw(x: r.minX + 7 + 6 + 5, capCenter: r.midY, in: ctx)
            cx = r.minX - 5
        }
        y += 20 + 12

        if m.bars.isEmpty {
            let r = CGRect(x: x0, y: y, width: w, height: 40)
            ctx.fill(rounded(r, 10), theme.tileFill)
            Glyph.ring(in: CGRect(x: r.minX + 10, y: r.midY - 7, width: 14, height: 14), fraction: 0.3, color: theme.muted, track: theme.muted.fade(0.3), lineWidth: 1.8, ctx: ctx)
            Text("No sessions yet", F.sf(12.5, 600), theme.ink).draw(x: r.minX + 32, baseline: r.minY + 17, in: ctx)
            Text("Each 5-hour session shows up here once it starts.", F.sf(11, 400), theme.muted).draw(x: r.minX + 32, baseline: r.minY + 31, in: ctx)
            return h
        }

        y += 2
        let area = CGRect(x: x0, y: y, width: w, height: barsH)
        // The warning line: sessions above it got a warning.
        let warnY = area.maxY - barsH * CGFloat(m.warnAt)
        let rule = CGMutablePath()
        rule.move(to: CGPoint(x: area.minX, y: warnY)); rule.addLine(to: CGPoint(x: area.maxX, y: warnY))
        ctx.stroke(rule, theme.amber.fade(0.4), width: 1, dash: [2, 3])

        let slots = CGFloat(maxBars), gap: CGFloat = 5
        let barW = (w - gap * (slots - 1)) / slots
        let brand = Brand.of(m.provider)
        var x = x0 + (w - (CGFloat(m.bars.count) * (barW + gap) - gap))
        var labels: [(x: CGFloat, text: String, now: Bool)] = []
        for bar in m.bars {
            let r = CGRect(x: x, y: area.minY, width: barW, height: barsH)
            let track = rounded(r, 5)
            ctx.fill(track, theme.isDark ? white(0.035) : black(0.03))
            let fh = max(barsH * CGFloat(bar.peak), 3)
            let fr = CGRect(x: r.minX, y: r.maxY - fh, width: r.width, height: fh)
            let fill = rounded(fr, 5)
            let (top, bottom): (NSColor, NSColor) = bar.hitLimit ? (rgb(0xFF8FA2), rgb(0xEE3459))
                : bar.peak >= m.warnAt ? (rgb(0xFFDA7A), rgb(0xF4A51F)) : (brand.light, brand.base)
            if bar.inProgress {
                ctx.fill(fill, bottom.fade(0.25))
                ctx.stroke(rounded(fr.insetBy(dx: 0.75, dy: 0.75), 4.5), top.fade(0.9), width: 1.3, dash: [2.5, 2])
            } else {
                if bar.hitLimit { ctx.glow(fill, color: rgb(0xEE3459, 0.5), blur: 8, base: bottom) }
                ctx.fillVertical(fill, top, bottom)
            }
            if bar.hitLimit {
                Glyph.pause(in: CGRect(x: r.midX - 3, y: fr.minY - 10, width: 6, height: 7), color: theme.rose, ctx: ctx)
            }
            if let label = bar.inProgress ? "NOW" : bar.dayLabel { labels.append((r.midX, label, bar.inProgress)) }
            out?.add(r.insetBy(dx: -gap / 2, dy: -4), tooltip: bar.tooltip)
            x += barW + gap
        }
        // Labels right to left, so NOW always shows and nothing overlaps.
        var lastX = CGFloat.infinity
        for l in labels.reversed() where lastX - l.x > 25 {
            lastX = l.x
            Text(l.text, F.sf(8, l.now ? 750 : 650), l.now ? theme.ink : theme.chartLabel, kern: 0.4)
                .draw(x: l.x + 0.2, baseline: area.maxY + 6 + 8, align: .center, in: ctx)
        }
        return h
    }
}
