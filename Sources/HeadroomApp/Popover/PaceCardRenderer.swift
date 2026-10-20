import AppKit
import HeadroomKit

/// Draws one Pace card (PLAN §7, mockup "Pace, dark"). Returns the card height.
@MainActor
enum PaceCardRenderer {
    static let padTop: CGFloat = 13, padX: CGFloat = 14, padBottom: CGFloat = 12

    @discardableResult
    static func draw(_ m: PaceCardModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput? = nil) -> CGFloat {
        let height = layout(m, origin: origin, width: width, theme: theme, ctx: nil, out: nil)
        guard let ctx else { return height }
        CardChrome.draw(CGRect(x: origin.x, y: origin.y, width: width, height: height), provider: m.provider, theme: theme, ctx: ctx)
        _ = layout(m, origin: origin, width: width, theme: theme, ctx: ctx, out: out)
        return height
    }

    /// One pass that both measures (ctx == nil) and draws.
    private static func layout(_ m: PaceCardModel, origin: CGPoint, width: CGFloat, theme: Theme, ctx: CGContext?, out: RenderOutput?) -> CGFloat {
        let x0 = origin.x + padX, w = width - padX * 2
        var y = origin.y + padTop

        // 1. Header: tile, name, plan pill, freshness.
        if let ctx { drawHeader(m, x: x0, y: y, w: w, theme: theme, ctx: ctx, out: out) }
        y += 28

        // 2. Session banner (≥ 75% used) — directly under the header.
        if let s = m.session {
            y += 12
            let h: CGFloat = 48
            if let ctx { drawSessionBanner(s, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // The detailed 5-hour panel takes the banner's place once it warns.
        if let s = m.sessionModule, s.onTop {
            y += 12
            let h = sessionModuleHeight(s, width: w)
            if let ctx { drawSessionModule(s, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // Fault banner replaces the callout; shown high so the reason is never missed.
        if let f = m.fault {
            y += 12
            let h = faultHeight(f, width: w)
            if let ctx { drawFault(f, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // 3. Hero.
        if let hero = m.hero {
            y += 15
            if let ctx { drawHero(hero, state: m.meter?.state ?? .onPace, x: x0, y: y, w: w, theme: theme, ctx: ctx, dim: m.meter?.opacity ?? 1) }
            y += 47 + 8 + 15
        }

        // 4. Meter + caret.
        if let meter = m.meter {
            y += 15
            let track = CGRect(x: x0, y: y, width: w, height: MeterRenderer.height)
            if let ctx { MeterRenderer.draw(meter, rect: track, theme: theme, ctx: ctx) }
            y += MeterRenderer.height
            if let caret = meter.caret {
                y += 4
                if let ctx { MeterRenderer.drawCaret(at: caret, trackRect: track, top: y, theme: theme, ctx: ctx) }
                y += 15
            }
        }

        // 5. Glide path.
        if let g = m.glide {
            y += 10
            let h = GlideChartRenderer.height(width: w)
            if let ctx { GlideChartRenderer.draw(g, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // 6. Verdict.
        if let v = m.verdict {
            y += 10
            y += drawVerdict(v, x: x0, y: y, w: w, theme: theme, ctx: ctx)
        }

        // The 5-hour panel while it's quiet: after the week's verdict.
        if let s = m.sessionModule, !s.onTop {
            y += 12
            let h = sessionModuleHeight(s, width: w)
            if let ctx { drawSessionModule(s, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // 7. Callout (at most one).
        if let c = m.callout, m.fault == nil {
            y += 10
            let h = calloutHeight(c, width: w)
            if let ctx { drawCallout(c, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx) }
            y += h
        }

        // 8. Detail rows.
        if !m.rows.isEmpty {
            y += 12
            let h = CGFloat(m.rows.count) * rowHeight
            if let ctx { drawRows(m.rows, rect: CGRect(x: x0, y: y, width: w, height: h), theme: theme, ctx: ctx, out: out) }
            y += h
        }

        y += padBottom
        return y - origin.y
    }

    // MARK: Header

    static func drawHeader(_ m: PaceCardModel, x: CGFloat, y: CGFloat, w: CGFloat, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        BrandMark.drawTile(m.provider, in: CGRect(x: x, y: y, width: 28, height: 28), ctx: ctx)
        let mid = y + 14
        let name = Text(m.provider.displayName, F.sf(15, 650), theme.ink, kern: -0.075)
        name.draw(x: x + 28 + 9, capCenter: mid, in: ctx)
        if let plan = m.plan {
            drawPill(plan, provider: m.provider, x: x + 37 + name.width + 9, midY: mid, theme: theme, ctx: ctx)
        }
        drawFreshness(m.freshness, right: x + w, midY: mid, theme: theme, ctx: ctx, out: out)
    }

    static func drawPill(_ text: String, provider: Provider, x: CGFloat, midY: CGFloat, theme: Theme, ctx: CGContext) {
        let brand = Brand.of(provider)
        let t = Text(text, F.sf(9.5, 700), brand.pillText(theme), kern: 0.95)
        let r = CGRect(x: x, y: midY - 8.2, width: t.width + 12 - 0.95, height: 16.4)
        let shape = rounded(r, 6)
        ctx.fill(shape, brand.base.fade(0.18))
        ctx.innerStroke(shape, brand.light.fade(0.28), width: 0.5)
        t.draw(x: r.minX + 6, capCenter: r.midY + 0.5, in: ctx)
    }

    static func drawFreshness(_ f: Freshness, right: CGFloat, midY: CGFloat, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let t = Text(f.text, F.sf(11.5, 500, tabular: true), theme.muted)
        t.draw(x: right, capCenter: midY, align: .right, in: ctx)
        let color: NSColor = switch f.status {
        case .fresh: theme.ok
        case .stale: theme.stale
        case .error: theme.error
        }
        let dotX = right - t.width - 6 - 3
        drawStatusDot(center: CGPoint(x: dotX, y: midY), color: color, ctx: ctx)
        out?.add(CGRect(x: dotX - 8, y: midY - 9, width: right - dotX + 8, height: 18), tooltip: f.tooltip)
    }

    // MARK: Session banner

    static func drawSessionBanner(_ s: SessionBannerModel, rect: CGRect, theme: Theme, ctx: CGContext) {
        let c = theme.session(s.level)
        let base = s.level == .amber ? rgb(0xF4A51F) : rgb(0xEE3459)
        let edge = s.level == .amber ? rgb(0xFFC248) : rgb(0xFF6982)
        let shape = rounded(rect, 13)
        ctx.fillLinear(shape, [base.fade(theme.isDark ? 0.17 : 0.14), base.fade(theme.isDark ? 0.07 : 0.05)],
                       from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.maxX, y: rect.midY))
        ctx.innerStroke(shape, edge.fade(theme.isDark ? 0.30 : 0.45), width: 1)
        let ringRect = CGRect(x: rect.minX + 9, y: rect.midY - 11, width: 22, height: 22)
        if s.level == .blocked {
            Glyph.ring(in: ringRect, fraction: 1, color: c, track: c.fade(0.18), ctx: ctx)
            Glyph.pause(in: CGRect(x: ringRect.midX - 3.4, y: ringRect.midY - 4, width: 6.8, height: 8), color: c, ctx: ctx)
        } else {
            Glyph.ring(in: ringRect, fraction: CGFloat(s.used), color: c, track: c.fade(0.18), ctx: ctx)
        }
        let tx = ringRect.maxX + 10
        let title = Text(s.title, F.sf(12.5, 650), c)
        title.draw(x: tx, baseline: baseline(top: rect.minY + 9, font: F.sf(12.5, 650), lineHeight: 15), in: ctx)
        Text(s.subtitle, F.sf(12, 400, tabular: true), theme.muted)
            .draw(x: tx, baseline: baseline(top: rect.minY + 9 + 15 + 1, font: F.sf(12), lineHeight: 14.4), in: ctx)
        let right = rect.maxX - 11
        Text(s.countdown, F.sf(17, 700, tabular: true), c).draw(x: right, baseline: rect.minY + 9 + 15, align: .right, in: ctx)
        Text(s.caption.uppercased(), F.sf(8.5, 650), c.fade(0.75), kern: 0.765)
            .draw(x: right + 0.765, baseline: rect.minY + 9 + 15 + 3 + 9.5, align: .right, in: ctx)
    }

    // MARK: Session module

    static func sessionForecastBlock(_ s: SessionModuleModel, width: CGFloat, color: NSColor) -> TextBlock {
        TextBlock(s.forecast, F.sf(12, 450), color, width: width - 24 - 13, lineHeight: 16)
    }

    static func sessionModuleHeight(_ s: SessionModuleModel, width: CGFloat) -> CGFloat {
        let forecast = sessionForecastBlock(s, width: width, color: .black).height
        let timeline: CGFloat = s.outlook == .idle ? 0 : 6 + 6 + 5 + 10
        return 48 + timeline + 9 + forecast + 12
    }

    static func drawSessionModule(_ s: SessionModuleModel, rect: CGRect, theme: Theme, ctx: CGContext) {
        let warn = s.level >= .amber
        let levelColor = theme.session(s.level)
        let tone = theme.pacing(s.tone)
        let shape = rounded(rect, 14)
        if warn {
            let base = s.level == .amber ? rgb(0xF4A51F) : rgb(0xEE3459)
            let edge = s.level == .amber ? rgb(0xFFC248) : rgb(0xFF6982)
            ctx.fillLinear(shape, [base.fade(theme.isDark ? 0.17 : 0.14), base.fade(theme.isDark ? 0.06 : 0.04)],
                           from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.innerStroke(shape, edge.fade(theme.isDark ? 0.30 : 0.45), width: 1)
        } else {
            ctx.fill(shape, theme.groupFill)
            ctx.innerStroke(shape, theme.groupBorder, width: 0.5)
        }

        // Ring, title and the countdown: the same grammar as the warning banner.
        let ringColor = warn ? levelColor : (s.outlook == .idle ? theme.muted : tone.text)
        let ringRect = CGRect(x: rect.minX + 11, y: rect.minY + 13, width: 22, height: 22)
        let track = warn ? levelColor.fade(0.18) : (theme.isDark ? white(0.12) : black(0.09))
        if s.level == .blocked {
            Glyph.ring(in: ringRect, fraction: 1, color: levelColor, track: track, ctx: ctx)
            Glyph.pause(in: CGRect(x: ringRect.midX - 3.4, y: ringRect.midY - 4, width: 6.8, height: 8), color: levelColor, ctx: ctx)
        } else {
            Glyph.ring(in: ringRect, fraction: CGFloat(s.used), color: ringColor, track: track, ctx: ctx)
        }
        let tx = ringRect.maxX + 10
        let right = rect.maxX - 12
        let countColor = warn ? levelColor : theme.ink
        let count = Text(s.countdown, F.sf(17, 700, tabular: true), countColor, kern: -0.2)
        count.draw(x: right, baseline: rect.minY + 9 + 15, align: .right, in: ctx)
        let caption = Text(s.caption.uppercased(), F.sf(8.5, 650), (warn ? levelColor : theme.muted).fade(0.8), kern: 0.765)
        caption.draw(x: right + 0.765, baseline: rect.minY + 9 + 15 + 3 + 9.5, align: .right, in: ctx)
        // Narrow cards drop words rather than collide with the countdown.
        let title = fit([s.title, s.title.replacingOccurrences(of: "5-hour session ", with: "Session ")], font: F.sf(12.5, 650),
                        width: right - count.width - 10 - tx)
        Text(title, F.sf(12.5, 650), warn ? levelColor : theme.ink)
            .draw(x: tx, baseline: baseline(top: rect.minY + 9, font: F.sf(12.5, 650), lineHeight: 15), in: ctx)
        let subtitle = fit([s.subtitle, s.subtitle.components(separatedBy: " · ").first ?? s.subtitle], font: F.sf(12, 400, tabular: true),
                           width: right - caption.width - 10 - tx)
        Text(subtitle, F.sf(12, 400, tabular: true), theme.muted)
            .draw(x: tx, baseline: baseline(top: rect.minY + 9 + 15 + 1, font: F.sf(12), lineHeight: 14.4), in: ctx)

        var y = rect.minY + 48
        if s.outlook != .idle {
            y += 6
            drawSessionTimeline(s, rect: CGRect(x: rect.minX + 12, y: y, width: rect.width - 24, height: 6), warn: warn, theme: theme, ctx: ctx)
            y += 6 + 5 + 10
        }

        // Forecast: a toned dot and one plain sentence.
        y += 9
        let block = sessionForecastBlock(s, width: rect.width, color: theme.ink.fade(0.86))
        let dotColor = s.outlook == .idle ? theme.muted2 : (s.outlook == .blocked ? theme.rose : tone.text)
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: rect.minX + 12, y: y + 8 - 3, width: 6, height: 6))
        ctx.withState {
            if s.outlook != .idle { ctx.setShadow(offset: .zero, blur: 6, color: dotColor.fade(0.8).cgColor) }
            ctx.fill(dot, dotColor)
        }
        block.draw(x: rect.minX + 12 + 6 + 7, top: y, in: ctx)
    }

    /// The first candidate that fits `width`, else the last.
    static func fit(_ candidates: [String], font: NSFont, width: CGFloat) -> String {
        candidates.first { Text($0, font, .black).width <= width } ?? candidates.last ?? ""
    }

    /// The 5 hours as a track: used so far, where the recent burn takes it by the reset, and now.
    static func drawSessionTimeline(_ s: SessionModuleModel, rect: CGRect, warn: Bool, theme: Theme, ctx: CGContext) {
        let track = rounded(rect, 3)
        ctx.fill(track, theme.isDark ? black(0.32) : black(0.07))
        if theme.isDark { ctx.innerStroke(track, white(0.05), width: 0.5) }
        let colors: (top: NSColor, bottom: NSColor, glow: NSColor) = {
            switch s.level {
            case .amber: return (rgb(0xFFDA7A), rgb(0xF4A51F), rgb(0xF4A51F, 0.5))
            case .rose, .blocked: return (rgb(0xFF8FA2), rgb(0xEE3459), rgb(0xEE3459, 0.55))
            case .normal:
                let p = theme.pacing(s.tone)
                return (p.top, p.bottom, p.glow)
            }
        }()
        let usedW = rect.width * CGFloat(min(max(s.used, 0), 1))
        if let p = s.projectedUsed, p > s.used + 0.005 {
            let pr = CGRect(x: rect.minX + usedW - 3, y: rect.minY, width: rect.width * CGFloat(p - s.used) + 3, height: rect.height)
            let shape = rounded(pr, 3)
            ctx.fill(shape, colors.bottom.fade(theme.isDark ? 0.26 : 0.22))
            // Striped like a forecast, not a fact.
            ctx.withState {
                ctx.addPath(shape); ctx.clip()
                var x = pr.minX - rect.height
                while x < pr.maxX {
                    let stripe = CGMutablePath()
                    stripe.move(to: CGPoint(x: x, y: pr.maxY)); stripe.addLine(to: CGPoint(x: x + rect.height, y: pr.minY))
                    ctx.stroke(stripe, colors.bottom.fade(0.45), width: 1.2)
                    x += 4
                }
            }
        }
        if usedW > 0.5 {
            let fill = rounded(CGRect(x: rect.minX, y: rect.minY, width: max(usedW, rect.height), height: rect.height), 3)
            ctx.glow(fill, color: colors.glow, blur: 7, base: colors.bottom)
            ctx.fillVertical(fill, colors.top, colors.bottom)
        }
        // Now: where even pace would have the fill.
        let nx = rect.minX + rect.width * CGFloat(min(max(s.elapsed, 0), 1))
        let tick = rounded(CGRect(x: nx - 1, y: rect.minY - 3, width: 2, height: rect.height + 6), 1)
        ctx.withState {
            ctx.setShadow(offset: .zero, blur: 2, color: (theme.isDark ? black(0.6) : white(0.9)).cgColor)
            ctx.fill(tick, theme.ink.fade(0.9))
        }
        let labelY = rect.maxY + 5 + 5
        let labelColor = theme.chartLabel
        let font = F.sf(8.5, 600, tabular: true)
        var leftEdge = rect.minX, rightEdge = rect.maxX
        if let start = s.startLabel {
            let t = Text(start, font, labelColor)
            t.draw(x: rect.minX, capCenter: labelY, in: ctx)
            leftEdge = rect.minX + t.width
        }
        if let end = s.endLabel {
            let t = Text(end, font, labelColor)
            t.draw(x: rect.maxX, capCenter: labelY, align: .right, in: ctx)
            rightEdge = rect.maxX - t.width
        }
        let now = Text("NOW", F.sf(8, 700), theme.ink.fade(0.62), kern: 0.6)
        if nx - now.width / 2 > leftEdge + 6, nx + now.width / 2 < rightEdge - 6 {
            now.draw(x: nx + 0.3, capCenter: labelY, align: .center, in: ctx)
        }
    }

    // MARK: Hero

    static func drawHero(_ h: HeroModel, state: PacingState, x: CGFloat, y: CGFloat, w: CGFloat, theme: Theme, ctx: CGContext, dim: Double) {
        let numFont = F.sf(56, 700, tabular: true)
        let num = Text("\(h.percentLeft)", numFont, theme.ink.fade(dim < 1 ? 0.7 : 1), kern: -2.8)
        let numBase = baseline(top: y, font: numFont, lineHeight: 47)
        num.draw(x: x - 1, baseline: numBase, in: ctx)
        // Raised "%": top-aligned with the digits' cap height.
        let pctFont = F.sf(23, 650)
        let capTop = numBase - numFont.capHeight
        Text("%", pctFont, theme.ink.fade(0.88)).draw(x: x - 1 + num.width + 3 + 2.8, baseline: capTop + 4 + pctFont.capHeight, in: ctx)
        let labelTop = y + 47 + 8
        Text(h.label, F.sf(12, 500), theme.muted).draw(x: x, baseline: baseline(top: labelTop, font: F.sf(12, 500), lineHeight: 15), in: ctx)

        let right = x + w
        let vFont = F.sf(32, 700, tabular: true)
        let v = Text(h.renewValue, vFont, theme.ink, kern: -1.12)
        let vBase = labelTop - 8 - 27.5 + baseline(top: 0, font: vFont, lineHeight: 27.5)
        v.draw(x: right + 1.12, baseline: vBase, align: .right, in: ctx)
        if h.hourglass {
            let hgH: CGFloat = 19
            let hx = right - v.width - 7 - hgH * 0.7
            Glyph.hourglass(in: CGRect(x: hx, y: vBase - vFont.capHeight / 2 - hgH / 2, width: hgH * 0.7, height: hgH), color: theme.pacing(.plenty).text, ctx: ctx)
        }
        Text(h.renewCaption, F.sf(12, 500, tabular: true), theme.muted)
            .draw(x: right, baseline: baseline(top: labelTop, font: F.sf(12, 500), lineHeight: 15), align: .right, in: ctx)
    }

    // MARK: Verdict

    static func drawVerdict(_ v: VerdictModel, x: CGFloat, y: CGFloat, w: CGFloat, theme: Theme, ctx: CGContext?) -> CGFloat {
        let primary = TextBlock(v.primary, F.sf(14), theme.ink, width: w, lineHeight: 19.3, kern: -0.07)
        let secondary = TextBlock(v.secondary, F.sf(12.5), theme.muted, width: w, lineHeight: 17.25)
        if let ctx {
            BadgeRenderer.draw(v.title, state: v.state, origin: CGPoint(x: x, y: y), theme: theme, ctx: ctx)
            Text(v.multiple + " pace", F.mono(11, 600), theme.muted).draw(x: x + w, capCenter: y + 11.5, align: .right, in: ctx)
            primary.draw(x: x, top: y + 23 + 8, in: ctx)
            secondary.draw(x: x, top: y + 23 + 8 + primary.height + 3, in: ctx)
        }
        return 23 + 8 + primary.height + 3 + secondary.height
    }

    // MARK: Callout

    static func calloutHeight(_ c: CalloutModel, width: CGFloat) -> CGFloat {
        let t = TextBlock(c.text, F.sf(12.5, 500), .black, width: width - 22 - 22 - 10, lineHeight: 16)
        return max(38, t.height + 16)
    }

    static func drawCallout(_ c: CalloutModel, rect: CGRect, theme: Theme, ctx: CGContext) {
        let tint: NSColor = switch c.kind {
        case .capEmpty: theme.rose
        case .capTight: theme.amber
        case .earlyReset: theme.azure
        }
        let shape = rounded(rect, 12)
        ctx.fill(shape, tint.fade(theme.isDark ? 0.10 : 0.08))
        ctx.innerStroke(shape, tint.fade(theme.isDark ? 0.26 : 0.30), width: 0.5)
        let icon = CGRect(x: rect.minX + 10, y: rect.midY - 11, width: 22, height: 22)
        ctx.fill(rounded(icon, 6.5), tint.fade(0.18))
        switch c.kind {
        case .capEmpty:
            Glyph.pause(in: CGRect(x: icon.midX - 3.6, y: icon.midY - 4.25, width: 7.2, height: 8.5), color: tint, ctx: ctx)
        case .capTight:
            Glyph.warning(in: icon.insetBy(dx: 4.5, dy: 4.5), fill: tint, ink: theme.cardSolid, ctx: ctx)
        case .earlyReset:
            Glyph.spark(in: icon.insetBy(dx: 6, dy: 6), color: tint, ctx: ctx)
        }
        let t = TextBlock(c.text, F.sf(12.5, 500), theme.ink.fade(0.92), width: rect.width - 22 - 22 - 10, lineHeight: 16)
        t.draw(x: icon.maxX + 10, top: rect.midY - t.height / 2, in: ctx)
    }

    // MARK: Fault

    static func faultHeight(_ f: FaultBannerModel, width: CGFloat) -> CGFloat {
        let t = TextBlock(f.message, F.sf(12.5, 600), .black, width: width - 54, lineHeight: 16)
        return t.height + (f.detail == nil ? 0 : 16) + 18
    }

    static func drawFault(_ f: FaultBannerModel, rect: CGRect, theme: Theme, ctx: CGContext) {
        let tint = theme.rose
        let shape = rounded(rect, 13)
        ctx.fill(shape, tint.fade(theme.isDark ? 0.11 : 0.08))
        ctx.innerStroke(shape, tint.fade(theme.isDark ? 0.28 : 0.32), width: 1)
        let icon = CGRect(x: rect.minX + 10, y: rect.minY + 9, width: 22, height: 22)
        ctx.fill(rounded(icon, 6.5), tint.fade(0.18))
        Glyph.warning(in: icon.insetBy(dx: 4.5, dy: 4.5), fill: tint, ink: theme.cardSolid, ctx: ctx)
        let t = TextBlock(f.message, F.sf(12.5, 600), theme.ink, width: rect.width - 54, lineHeight: 16)
        t.draw(x: icon.maxX + 10, top: rect.minY + 9 + 3, in: ctx)
        if let d = f.detail {
            Text(d, F.sf(11.5, 500, tabular: true), theme.muted)
                .draw(x: icon.maxX + 10, baseline: baseline(top: rect.minY + 12 + t.height, font: F.sf(11.5, 500), lineHeight: 16), in: ctx)
        }
    }

    // MARK: Detail rows

    static let rowHeight: CGFloat = 38

    static func drawRows(_ rows: [DetailRowModel], rect: CGRect, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let shape = rounded(rect, 14)
        ctx.fill(shape, theme.groupFill)
        ctx.innerStroke(shape, theme.groupBorder, width: 0.5)
        for (i, row) in rows.enumerated() {
            let r = CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * rowHeight, width: rect.width, height: rowHeight)
            if i > 0 {
                ctx.fill(CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: 0.5), transform: nil), theme.separator)
            }
            let icon = CGRect(x: r.minX + 10, y: r.midY - 11, width: 22, height: 22)
            drawRowIcon(row.icon, highlight: row.highlight, rect: icon, theme: theme, ctx: ctx)
            Text(row.label, F.sf(12.5), theme.muted).draw(x: icon.maxX + 10, capCenter: r.midY, in: ctx)
            let right = r.maxX - 10
            var vx = right
            if let suffix = row.suffix {
                let s = Text(suffix, F.sf(12.5, 500, tabular: true), theme.muted)
                s.draw(x: right, capCenter: r.midY, align: .right, in: ctx)
                vx = right - s.width - 5
            }
            let vColor = row.highlight ? theme.azureLight : theme.ink
            Text(row.value, F.sf(12.5, 600, tabular: true), vColor).draw(x: vx, capCenter: r.midY, align: .right, in: ctx)
            if row.tooltip != nil { out?.add(r, tooltip: row.tooltip) }
        }
    }

    static func drawRowIcon(_ icon: DetailRowModel.Icon, highlight: Bool, rect: CGRect, theme: Theme, ctx: CGContext) {
        let tile = rounded(rect, 6.5)
        switch icon {
        case .ring(let used, let level):
            ctx.fill(tile, theme.isDark ? white(0.07) : black(0.05))
            let c = level == .normal ? theme.ink.fade(theme.isDark ? 0.93 : 0.8) : theme.session(level)
            Glyph.ring(in: rect.insetBy(dx: 4, dy: 4), fraction: CGFloat(used), color: c, track: theme.isDark ? white(0.14) : black(0.12), ctx: ctx)
        case .hourglass(let hot):
            ctx.fill(tile, hot || highlight ? rgb(0x4A8EFF, 0.18) : (theme.isDark ? white(0.07) : black(0.05)))
            let c = hot || highlight ? theme.azureLight : theme.muted
            Glyph.hourglass(in: CGRect(x: rect.midX - 4.2, y: rect.midY - 6, width: 8.4, height: 12), color: c, ctx: ctx)
        case .coin(let p):
            let b = Brand.of(p)
            ctx.fill(tile, b.base.fade(0.2))
            Glyph.coin(in: CGRect(x: rect.midX - 6.5, y: rect.midY - 6.5, width: 13, height: 13), color: theme.isDark ? b.light : b.base, ctx: ctx)
        }
    }
}
