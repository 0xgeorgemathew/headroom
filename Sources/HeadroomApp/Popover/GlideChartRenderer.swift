import AppKit
import HeadroomKit

/// The weekly glide path (PLAN §3.4): remaining allowance over the window, drawn in the
/// mockup's 300×124 coordinate space and scaled to the card width.
@MainActor
enum GlideChartRenderer {
    static let vbW: CGFloat = 300, vbH: CGFloat = 124

    static func height(width: CGFloat) -> CGFloat { vbH * width / vbW }

    static func draw(_ g: GlideModel, rect: CGRect, theme: Theme, ctx: CGContext, calendar: Calendar = .current, locale: Locale = .current) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / vbW, y: rect.width / vbW)
        render(g, theme: theme, ctx: ctx, calendar: calendar, locale: locale)
        ctx.restoreGState()
    }

    private static func render(_ g: GlideModel, theme: Theme, ctx: CGContext, calendar: Calendar, locale: Locale) {
        let W = vbW, H = vbH, top: CGFloat = 12, bot = H - 22
        let hours = max(g.hours, 1)
        func X(_ h: Double) -> CGFloat { CGFloat(h / hours) * W }
        func Y(_ r: Double) -> CGFloat { top + CGFloat(1 - r) * (bot - top) }
        let col: NSColor = g.brandLine.map { theme.isDark ? Brand.of($0).light : Brand.of($0).base } ?? theme.pacing(g.state).text
        let warnCol = theme.rose

        // Day boundaries at local midnight; weekly boundaries for long (monthly) windows.
        let weekly = hours > 240
        var bounds: [Double] = [0]
        if let firstMidnight = calendar.nextDate(after: g.windowStart, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            var d = firstMidnight
            while true {
                let h = d.timeIntervalSince(g.windowStart) / 3600
                if h >= hours { break }
                if h > 0.01 { bounds.append(h) }
                guard let next = calendar.date(byAdding: .day, value: weekly ? 7 : 1, to: d) else { break }
                d = next
            }
        }
        bounds.append(hours)

        // Grid.
        ctx.stroke(line(0, Y(1), W, Y(1)), theme.chartGrid, width: 1)
        ctx.stroke(line(0, Y(0), W, Y(0)), theme.chartGrid, width: 1.2)
        for b in bounds.dropFirst().dropLast() { ctx.stroke(line(X(b), top, X(b), bot), theme.chartGrid, width: 1) }

        // Projection end and the run-out day.
        let endT = min(max(g.projectionEnd.t, g.nowT), hours)
        let endR = max(0, g.projectionEnd.remaining)
        var warnDay: Int? = nil
        if g.runsOut {
            warnDay = bounds.indices.dropLast().first { endT >= bounds[$0] && endT < bounds[$0 + 1] }
        }

        // Day labels; today in a pill.
        let dayFont = F.sf(8.5, 600), dayFontBold = F.sf(8.5, 750)
        for i in 0..<(bounds.count - 1) where bounds[i + 1] - bounds[i] >= (weekly ? 72 : 12) {
            let cx = X((bounds[i] + bounds[i + 1]) / 2)
            let current = g.nowT >= bounds[i] && g.nowT < bounds[i + 1]
            let warn = warnDay == i
            if current && !weekly { ctx.fill(rounded(CGRect(x: cx - 15, y: H - 15, width: 30, height: 14), 7), theme.chartPill) }
            let date = g.windowStart.addingTimeInterval((bounds[i] + 0.5) * 3600)
            let name = weekly ? monthDayLabel(g.windowStart.addingTimeInterval(bounds[i] * 3600), calendar: calendar, locale: locale)
                : weekdayAbbrev(date, calendar: calendar, locale: locale)
            let color = warn ? warnCol : current ? theme.ink : theme.chartLabel
            let label = Text(name, current || warn ? dayFontBold : dayFont, color, kern: 0.7)
            if current && weekly {
                // Widen today's pill to fit a date.
                ctx.fill(rounded(CGRect(x: cx - label.width / 2 - 7, y: H - 15, width: label.width + 14, height: 14), 7), theme.chartPill)
            }
            label.draw(x: cx + 0.35, baseline: H - 5, align: .center, in: ctx)
        }

        // Even pace diagonal.
        ctx.stroke(line(0, Y(1), W, Y(0)), theme.chartDash, width: 1, dash: [3, 4])

        // History → runs split at gaps > 2 h.
        let pts = g.points.filter { $0.t >= 0 && $0.t <= g.nowT + 0.01 }.sorted { $0.t < $1.t }
        // Split at real gaps first (Mac asleep or off), then thin each run for a smooth curve.
        var rawRuns: [[GlideModel.Point]] = []
        var lastT: Double? = nil
        for p in pts {
            if let lt = lastT, p.t - lt <= 2.0, !rawRuns.isEmpty { rawRuns[rawRuns.count - 1].append(p) } else { rawRuns.append([p]) }
            lastT = p.t
        }
        var runs: [[CGPoint]] = rawRuns.map { run in decimate(run, step: hours / 56).map { CGPoint(x: X($0.t), y: Y(1 - $0.used)) } }
        let nowUsed = pts.last?.used ?? (1 - endR)
        let nx = X(g.nowT), ny = Y(1 - nowUsed)
        if runs.isEmpty { runs = [[CGPoint(x: 0, y: Y(1)), CGPoint(x: nx, y: ny)]] }
        if let l = runs.last?.last, abs(l.x - nx) > 0.5 { runs[runs.count - 1].append(CGPoint(x: nx, y: ny)) }

        let curve = CGMutablePath()
        var gapSegments: [(CGPoint, CGPoint)] = []
        for (i, run) in runs.enumerated() {
            let s = smoothPath(run)
            if i == 0 { curve.addPath(s) } else {
                if let prev = runs[i - 1].last, let first = run.first { gapSegments.append((prev, first)); curve.addLine(to: first) }
                curve.addPath(s)
            }
        }
        // Area fill under the whole history.
        let area = CGMutablePath()
        area.addPath(curveForArea(runs))
        area.addLine(to: CGPoint(x: nx, y: Y(0)))
        area.addLine(to: CGPoint(x: runs.first?.first?.x ?? 0, y: Y(0)))
        area.closeSubpath()
        ctx.fillLinear(area, [col.fade(0.30), col.fade(0.06), col.fade(0)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bot), locations: [0, 0.75, 1])

        // Now drop line.
        ctx.stroke(line(nx, ny, nx, Y(0)), col.fade(0.45), width: 1, dash: [2, 3])

        // Line with glow; gaps dotted.
        for run in runs {
            let s = smoothPath(run)
            ctx.withState {
                ctx.setAlpha(0.55)
                ctx.glowStroke(s, color: col, width: 4, blur: 5.2)
            }
            ctx.stroke(s, col, width: 2.1, cap: .round, join: .round)
        }
        for (a, b) in gapSegments {
            ctx.withState { ctx.setAlpha(0.85); ctx.stroke(line(a.x, a.y, b.x, b.y), col, width: 2, dash: [0.1, 4.4], cap: .round) }
        }

        // Projection.
        let ex = X(endT), ey = Y(endR)
        ctx.withState { ctx.setAlpha(0.85); ctx.stroke(line(nx, ny, ex, ey), col, width: 2, dash: [0.1, 4.4], cap: .round) }
        if g.runsOut {
            let halo = CGMutablePath(); halo.addEllipse(in: CGRect(x: ex - 9, y: ey - 9, width: 18, height: 18))
            ctx.fill(halo, warnCol.fade(0.18))
            Glyph.warning(in: CGRect(x: ex - 7, y: ey - 12, width: 14, height: 14), fill: warnCol, ink: theme.cardSolid, ctx: ctx)
        } else {
            let end = CGMutablePath(); end.addEllipse(in: CGRect(x: ex - 1.5 - 3, y: ey - 3, width: 6, height: 6))
            ctx.fill(end, theme.cardSolid)
            ctx.stroke(end, col, width: 1.6)
            if let label = g.endLabel {
                Text(label, F.sf(9.5, 650), col).draw(x: W, baseline: ey + 16, align: .right, in: ctx)
            }
        }

        // Now dot and chip.
        let haloNow = CGMutablePath(); haloNow.addEllipse(in: CGRect(x: nx - 8, y: ny - 8, width: 16, height: 16))
        ctx.fill(haloNow, col.fade(0.22))
        let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: nx - 3.8, y: ny - 3.8, width: 7.6, height: 7.6))
        ctx.fill(dot, col)
        ctx.stroke(dot, theme.cardSolid, width: 2)
        let cw: CGFloat = 28
        let cx = min(max(nx, cw / 2 + 1), W - cw / 2 - 1)
        let chip = rounded(CGRect(x: cx - cw / 2, y: ny - 23, width: cw, height: 13), 6.5)
        ctx.fill(chip, col.fade(0.16))
        ctx.stroke(chip, col.fade(0.4), width: 0.6)
        Text("NOW", F.sf(7.8, 800), col, kern: 0.8).draw(x: cx + 0.4, baseline: ny - 13.6, align: .center, in: ctx)

        // EVEN PACE label in the emptier half, outlined in the card color.
        let evenAt = g.nowT > hours * 0.6 ? g.nowT * 0.75 : g.nowT + (hours - g.nowT) * 0.6
        let ly = Y(1 - evenAt / hours) - 6
        let label = NSMutableAttributedString(string: "EVEN PACE", attributes: [.font: F.sf(8.5, 650), .kern: 0.6, .foregroundColor: theme.chartLabel])
        drawOutlined(label, center: CGPoint(x: X(evenAt), y: ly), outline: theme.cardSolid, ctx: ctx)
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
        let p = CGMutablePath(); p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)); return p
    }

    private static func curveForArea(_ runs: [[CGPoint]]) -> CGPath {
        let p = CGMutablePath()
        for (i, run) in runs.enumerated() {
            let s = smoothPath(run)
            if i == 0 { p.addPath(s) } else if let f = run.first { p.addLine(to: f); p.addPath(smoothPathContinuing(run)) }
            _ = s
        }
        return p
    }

    /// Same as smoothPath but continues the current subpath (no moveTo).
    private static func smoothPathContinuing(_ pts: [CGPoint]) -> CGPath {
        let full = smoothPath(pts)
        let p = CGMutablePath()
        var first = true
        full.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint: if first { first = false } // skip
            case .addLineToPoint: p.addLine(to: e.points[0])
            case .addCurveToPoint: p.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .addQuadCurveToPoint: p.addQuadCurve(to: e.points[1], control: e.points[0])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        return p
    }

    /// Keeps at most one point per `step` hours (plus the last), so the curve stays smooth.
    private static func decimate(_ pts: [GlideModel.Point], step: Double) -> [GlideModel.Point] {
        guard pts.count > 2 else { return pts }
        var out: [GlideModel.Point] = [pts[0]]
        for p in pts.dropFirst().dropLast() where p.t - out[out.count - 1].t >= step {
            out.append(p)
        }
        out.append(pts[pts.count - 1])
        return out
    }

    private static func weekdayAbbrev(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
    }

    private static func monthDayLabel(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date).uppercased()
    }

    private static func drawOutlined(_ s: NSAttributedString, center: CGPoint, outline: NSColor, ctx: CGContext) {
        let outlined = NSMutableAttributedString(attributedString: s)
        let range = NSRange(location: 0, length: outlined.length)
        outlined.addAttributes([.strokeColor: outline, .strokeWidth: 3 / 8.5 * 100, .foregroundColor: outline], range: range)
        let w = Text([Text(s.string, F.sf(8.5, 650), .black, kern: 0.6)]).width
        for str in [outlined as NSAttributedString, s] {
            let line = CTLineCreateWithAttributedString(str)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: center.x - w / 2, y: center.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
