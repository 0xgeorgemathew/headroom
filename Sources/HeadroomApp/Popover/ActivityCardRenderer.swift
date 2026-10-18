import AppKit
import HeadroomKit

/// Activity card (PLAN §7, mockup "Activity, light, All").
@MainActor
enum ActivityCardRenderer {
    static let padTop: CGFloat = 13, padX: CGFloat = 14, padBottom: CGFloat = 12
    static let chartVB = CGSize(width: 300, height: 118)

    struct Layout {
        var chartRect: CGRect = .zero
        var barWidth: CGFloat = 0
        var barCount: Int = 0
        var breakdownHeader: CGRect = .zero
    }

    @discardableResult
    static func draw(_ m: ActivityCardModel, mode: ActivityMode, breakdown: BreakdownKind, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil, layout: UnsafeMutablePointer<Layout>? = nil) -> CGFloat {
        let h = pass(m, mode: mode, breakdown: breakdown, origin: origin, width: width, theme: theme, ctx: nil, out: nil, layout: nil)
        guard let ctx else { return h }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: h), provider: m.provider, theme: theme, ctx: ctx)
        _ = pass(m, mode: mode, breakdown: breakdown, origin: origin, width: width, theme: theme, ctx: ctx, out: out, layout: layout)
        return h
    }

    private static func pass(_ m: ActivityCardModel, mode: ActivityMode, breakdown: BreakdownKind, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput?, layout: UnsafeMutablePointer<Layout>?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + padTop
        let brand = Brand.of(m.provider)

        // Header: tile, name, span chip.
        if let ctx {
            BrandMark.drawTile(m.provider, in: CGRect(x: x0, y: y, width: 26, height: 26), ctx: ctx)
            Text(m.provider.displayName, F.sf(15, 650), theme.ink, kern: -0.075).draw(x: x0 + 26 + 9, capCenter: y + 13, in: ctx)
            let label = Text(m.spanLabel, F.sf(11.5, 600, tabular: true), theme.ink)
            let chipW = 8 + 12 + 5 + label.width + 8
            let chip = CGRect(x: x0 + w - chipW, y: y + 13 - 11, width: chipW, height: 22)
            ctx.fill(rounded(chip, 8), theme.chipFill)
            Glyph.calendar(in: CGRect(x: chip.minX + 8, y: chip.midY - 6, width: 12, height: 12), color: theme.muted, ctx: ctx)
            label.draw(x: chip.minX + 8 + 12 + 5, capCenter: chip.midY, in: ctx)
            out?.add(chip, tooltip: m.spanLong)
        }
        y += 26

        // Hero: tokens and API cost for the span.
        y += 12
        let tokens = mode == .all ? m.totals.total : m.totals.fresh
        if let ctx {
            let big = Text(NumberFormat.tokens(tokens), F.sf(34, 700, tabular: true), theme.ink, kern: -1.36)
            let b = baseline(top: y, font: F.sf(34, 700), lineHeight: 30.6)
            big.draw(x: x0 - 0.5, baseline: b, in: ctx)
            Text(mode == .all ? "tokens" : "new tokens", F.sf(13, 600), theme.muted).draw(x: x0 + big.width + 5, baseline: b, in: ctx)
            let cost = Text(NumberFormat.dollars(micros: m.micros, style: .precise), F.sf(21, 700, tabular: true), theme.ink, kern: -0.42)
            let cb = y + 30.6 - 18.9 - 5 - 14 + baseline(top: 0, font: F.sf(21, 700), lineHeight: 18.9)
            cost.draw(x: x0 + w + 0.42, baseline: cb, align: .right, in: ctx)
            Text("at API rates", F.sf(11.5, 500), theme.muted).draw(x: x0 + w, baseline: cb + 5 + 12, align: .right, in: ctx)
        }
        y += 30.6

        // Chart.
        y += 12
        let ch = chartVB.height * w / chartVB.width
        let chart = CGRect(x: x0, y: y, width: w, height: ch)
        if let ctx { drawBars(m, mode: mode, rect: chart, theme: theme, ctx: ctx) }
        if let layout {
            let s = w / chartVB.width
            layout.pointee.chartRect = CGRect(x: x0, y: y, width: (chartVB.width - 30) * s, height: (chartVB.height - 18) * s)
            layout.pointee.barCount = m.bars.count
            layout.pointee.barWidth = m.bars.isEmpty ? 0 : (chartVB.width - 30) * s / CGFloat(m.bars.count)
        }
        y += ch

        // Stat tiles.
        y += 10
        let t = m.totals
        let total = max(1, Double(mode == .all ? t.total : t.fresh))
        let tiles: [(String, Int64, NSColor)] = mode == .all
            ? [("Cached", t.cacheRead, brand.base.fade(0.35)), ("New input", t.newInput + t.cacheWrite, brand.newInput), ("Output", t.output, brand.deep)]
            : [("New input", t.newInput, brand.newInput), ("Cache write", t.cacheWrite, brand.base.fade(0.5)), ("Output", t.output, brand.deep)]
        let tileW = (w - 12) / 3, tileH: CGFloat = 49
        if let ctx {
            for (i, tile) in tiles.enumerated() {
                let r = CGRect(x: x0 + CGFloat(i) * (tileW + 6), y: y, width: tileW, height: tileH)
                ctx.fill(rounded(r, 11), theme.tileFill)
                ctx.fill(rounded(CGRect(x: r.minX + 9, y: r.minY + 8 + 3.6, width: 7, height: 7), 2.5), tile.2)
                Text(tile.0, F.sf(11, 500), theme.muted).draw(x: r.minX + 9 + 12, baseline: baseline(top: r.minY + 8, font: F.sf(11, 500), lineHeight: 14), in: ctx)
                let v = Text(NumberFormat.tokens(tile.1), F.sf(15, 700, tabular: true), theme.ink, kern: -0.15)
                let vb = baseline(top: r.minY + 8 + 14 + 3, font: F.sf(15, 700), lineHeight: 17)
                v.draw(x: r.minX + 9, baseline: vb, in: ctx)
                Text(NumberFormat.percent(Double(tile.1) / total), F.sf(11, 500, tabular: true), theme.ink.fade(0.45)).draw(x: r.minX + 9 + v.width + 4, baseline: vb, in: ctx)
            }
        }
        y += tileH

        // Composition bar.
        y += 9
        if let ctx {
            let shares = tiles.map { Double($0.1) / total }
            let mins: [CGFloat] = [0, 10, 5]
            let bar = CGRect(x: x0, y: y, width: w, height: 5)
            ctx.withState {
                ctx.addPath(rounded(bar, 3)); ctx.clip()
                let avail = w - 4
                var widths = shares.enumerated().map { max(mins[$0.offset], CGFloat($0.element) * avail) }
                let excess = widths.reduce(0, +) - avail
                if excess > 0, let big = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[big] -= excess }
                var x = x0
                for (i, wd) in widths.enumerated() where wd > 0 {
                    let color = i == 0 && mode == .all ? brand.base.fade(theme.isDark ? 0.45 : 0.32) : tiles[i].2
                    ctx.fill(CGPath(rect: CGRect(x: x, y: y, width: wd, height: 5), transform: nil), color)
                    x += wd + 2
                }
            }
        }
        y += 5

        // Breakdown.
        y += 11
        let rows = m.breakdown[breakdown] ?? []
        if let ctx {
            let head = Text(breakdown.title + " ▾", F.sf(11.5, 600), theme.muted)
            head.draw(x: x0, baseline: baseline(top: y, font: F.sf(11.5, 600), lineHeight: 14), in: ctx)
            out?.add(CGRect(x: x0 - 4, y: y - 3, width: head.width + 8, height: 20), tooltip: "Break down by model, project or token class", action: .breakdownMenu(m.provider))
            Text("incl. cached reads", F.sf(11.5, 500), theme.ink.fade(0.4)).draw(x: x0 + w, baseline: baseline(top: y, font: F.sf(11.5, 500), lineHeight: 14), align: .right, in: ctx)
        }
        if let layout { layout.pointee.breakdownHeader = CGRect(x: x0 - 4, y: y - 3, width: 120, height: 20) }
        y += 14
        for row in rows {
            y += 7
            if let ctx {
                let b = baseline(top: y, font: F.sf(12), lineHeight: 14.4)
                let nameW: CGFloat = 86, pctW: CGFloat = 30, costW: CGFloat = 54
                Text(truncate(row.name, width: nameW + 20), F.sf(12), theme.ink).draw(x: x0, baseline: b, in: ctx)
                let barX = x0 + nameW + 8, barW = w - nameW - costW - pctW - 24
                let track = CGRect(x: barX, y: y + 4.7, width: barW, height: 5)
                ctx.fill(rounded(track, 2.5), theme.isDark ? white(0.06) : black(0.05))
                let p = row.share * 100
                ctx.fill(rounded(CGRect(x: barX, y: track.minY, width: max(2, barW * CGFloat(row.share)), height: 5), 2.5), brand.base.fade(0.45 + p / 180))
                Text(NumberFormat.dollars(micros: row.micros, style: .precise), F.sf(12, 600, tabular: true), theme.ink).draw(x: x0 + w - pctW - 8, baseline: b, align: .right, in: ctx)
                Text("\(Int(p.rounded()))%", F.sf(11, 400, tabular: true), theme.ink.fade(0.42)).draw(x: x0 + w, baseline: b, align: .right, in: ctx)
            }
            y += 14.4
        }
        if let note = m.footnote {
            y += 9
            let block = TextBlock(note, F.sf(10.5, 500), theme.muted2, width: w, lineHeight: 13)
            if let ctx { block.draw(x: x0, top: y, in: ctx) }
            y += block.height
        }
        y += padBottom
        return y - origin.y
    }

    private static func truncate(_ s: String, width: CGFloat) -> String {
        var t = s
        while Text(t, F.sf(12), .black).width > width, t.count > 4 { t = String(t.dropLast(2)) + "…" }
        return t
    }

    // MARK: Bars

    static func niceMax(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v)))
        for m in [1.0, 2, 2.5, 4, 5, 8, 10] where m * e >= v * 1.04 { return m * e }
        return 10 * e
    }

    static func drawBars(_ m: ActivityCardModel, mode: ActivityMode, rect: CGRect, theme: Theme, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        let s = rect.width / chartVB.width
        ctx.scaleBy(x: s, y: s)
        let W = chartVB.width, H = chartVB.height, R: CGFloat = 30, ch = H - 18
        let n = max(m.bars.count, 1)
        let cw = (W - R) / CGFloat(n)
        let values = m.bars.map { Double(mode == .all ? $0.tokens.total : $0.tokens.fresh) }
        let maxV = niceMax(values.max() ?? 0)
        func Y(_ v: Double) -> CGFloat { ch - CGFloat(v / maxV) * (ch - 10) }
        let brand = Brand.of(m.provider)
        let labelColor = theme.chartLabel

        for g in [maxV, maxV / 2, 0] {
            let y = Y(g)
            let line = CGMutablePath(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: W - R + 2, y: y))
            ctx.stroke(line, g > 0 ? theme.chartGrid : theme.chartBaseline, width: 1)
            Text(g > 0 ? NumberFormat.tokens(Int64(g)) : "0", F.sf(9.5, 550, tabular: true), labelColor).draw(x: W, baseline: y + 3.5, align: .right, in: ctx)
        }

        let sel = m.selection.clamped(to: 0..<n)
        let sx = CGFloat(sel.lowerBound) * cw, sw = CGFloat(sel.count) * cw
        let lens = rounded(CGRect(x: sx, y: 2, width: sw, height: ch - 2), 8)
        ctx.fill(lens, brand.base.fade(theme.isDark ? 0.10 : 0.07))
        ctx.stroke(lens, brand.base.fade(0.45), width: 1)

        for (i, bar) in m.bars.enumerated() {
            let v = values[i]
            guard v > 0 else { continue }
            let x = CGFloat(i) * cw + min(2.2, cw * 0.18), bw = cw - 2 * min(2.2, cw * 0.18)
            let y = Y(v), h = ch - y
            let dim = !sel.contains(i)
            ctx.withState {
                ctx.setAlpha(dim ? 0.42 : 1)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                let shape = rounded(CGRect(x: x, y: y, width: bw, height: h), min(3, bw / 2))
                let t = bar.tokens
                if mode == .all {
                    ctx.fill(shape, brand.base.fade(theme.isDark ? 0.26 : 0.2))
                    ctx.stroke(shape, brand.base.fade(0.38), width: 0.7)
                    ctx.fill(rounded(CGRect(x: x + 1, y: y + 0.7, width: max(bw - 2, 0.5), height: 1.1), 0.55), white(theme.isDark ? 0.55 : 0.95))
                    let ho = max(1.6, h * CGFloat(Double(t.output) / v)), hn = max(1.8, h * CGFloat(Double(t.newInput + t.cacheWrite) / v))
                    ctx.fill(rounded(CGRect(x: x + 1, y: ch - 1 - ho - hn, width: max(bw - 2, 0.5), height: hn), 1), brand.newInput)
                    ctx.fill(rounded(CGRect(x: x + 1, y: ch - 1 - ho, width: max(bw - 2, 0.5), height: ho), 1), brand.deep)
                } else {
                    // Solid bars: new input on top of output.
                    ctx.fillVertical(shape, brand.light, brand.base)
                    let ho = max(1.6, h * CGFloat(Double(t.output) / v))
                    ctx.withState {
                        ctx.addPath(shape); ctx.clip()
                        ctx.fill(CGPath(rect: CGRect(x: x, y: ch - ho, width: bw, height: ho), transform: nil), brand.deep)
                    }
                    ctx.fill(rounded(CGRect(x: x + 1, y: y + 0.7, width: max(bw - 2, 0.5), height: 1.1), 0.55), white(0.55))
                }
                ctx.endTransparencyLayer()
            }
        }

        // Lens handles.
        for gx in [sx, sx + sw] {
            let handle = rounded(CGRect(x: gx - 2.5, y: ch / 2 - 11, width: 5, height: 22), 2.5)
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: black(0.18).cgColor)
                ctx.fill(handle, theme.isDark ? rgb(0xF4F4F6) : .white)
            }
            ctx.stroke(handle, brand.base, width: 1)
            let l = CGMutablePath(); l.move(to: CGPoint(x: gx, y: ch / 2 - 5)); l.addLine(to: CGPoint(x: gx, y: ch / 2 + 5))
            ctx.stroke(l, brand.base.fade(0.6), width: 1)
        }

        for label in m.axisLabels {
            Text(label.text, F.sf(9.5, 550), labelColor).draw(x: CGFloat(label.index) * cw + 1, baseline: H - 3, in: ctx)
        }
        ctx.restoreGState()
    }
}
