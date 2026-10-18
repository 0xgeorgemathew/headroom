import AppKit
import HeadroomKit

/// Copy Card (1200×675) and Copy Snapshot, drawn offscreen at 2× (PLAN §8, mockup "Copy Card").
@MainActor
enum ShareCardRenderer {
    static let size = CGSize(width: 1200, height: 675)
    static let theme = Theme.dark

    static func card(_ s: ShareModel) -> NSBitmapImageRep? {
        renderImage(size: size, scale: 2) { ctx in draw(s, ctx: ctx) }
    }

    static func snapshot(_ shares: [ShareModel]) -> NSBitmapImageRep? {
        renderImage(size: size, scale: 2) { ctx in drawSnapshot(shares, ctx: ctx) }
    }

    // MARK: Background and chrome

    private static func background(_ provider: Provider?, ctx: CGContext) {
        let full = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        ctx.fillLinear(full, [rgb(0x17181D), rgb(0x0E0F13)], from: CGPoint(x: 400, y: 0), to: CGPoint(x: 800, y: 675))
        let brand = provider.map { Brand.of($0).base } ?? rgb(0xD97757)
        ctx.fillRadial(in: full, center: CGPoint(x: 72, y: 675), radii: CGSize(width: 660, height: 506), color: brand.alpha(0.42), fadeAt: 0.7)
        ctx.fillRadial(in: full, center: CGPoint(x: 1200, y: 0), radii: CGSize(width: 540, height: 371), color: rgb(0x4A8EFF, 0.2), fadeAt: 0.7)
    }

    private static func logo(ctx: CGContext) {
        HeadroomMark.draw(in: CGRect(x: 72, y: 60, width: 52, height: 52), ctx: ctx)
        Text("Headroom", F.sf(34, 650), theme.ink, kern: -0.34).draw(x: 72 + 52 + 16, capCenter: 86, in: ctx)
    }

    private static func chip(_ text: String, right: CGFloat, midY: CGFloat, ctx: CGContext) -> CGFloat {
        let t = Text(text, F.sf(22, 600), rgb(0xF4F4F6, 0.85))
        let w = 18 + 20 + 10 + t.width + 18
        let r = CGRect(x: right - w, y: midY - 23, width: w, height: 46)
        ctx.fill(rounded(r, 14), white(0.07))
        ctx.innerStroke(rounded(r, 14), white(0.08), width: 1)
        Glyph.calendar(in: CGRect(x: r.minX + 18, y: r.midY - 10, width: 20, height: 20), color: rgb(0xF4F4F6, 0.7), ctx: ctx)
        t.draw(x: r.minX + 18 + 20 + 10, capCenter: r.midY, in: ctx)
        return r.minX
    }

    private static func planPill(_ text: String, provider: Provider, right: CGFloat, midY: CGFloat, ctx: CGContext) -> CGFloat {
        let brand = Brand.of(provider)
        let t = Text(text, F.sf(18, 750), brand.light, kern: 1.8)
        let w = 16 + t.width - 1.8 + 16
        let r = CGRect(x: right - w, y: midY - 22, width: w, height: 44)
        ctx.fill(rounded(r, 14), brand.base.alpha(0.2))
        ctx.innerStroke(rounded(r, 14), brand.light.alpha(0.25), width: 1)
        t.draw(x: r.minX + 16, capCenter: r.midY, in: ctx)
        return r.minX
    }

    private static func accent(_ p: Provider) -> NSColor { p == .claude ? rgb(0xF2A385) : rgb(0x5FD9B4) }

    // MARK: Copy Card

    static func draw(_ s: ShareModel, ctx: CGContext) {
        background(s.provider, ctx: ctx)
        logo(ctx: ctx)
        var right: CGFloat = 1200 - 72
        if let plan = s.plan { right = planPill(plan, provider: s.provider, right: right, midY: 88, ctx: ctx) - 12 }
        _ = chip(s.spanLong, right: right, midY: 88, ctx: ctx)

        BrandMark.drawTile(s.provider, in: CGRect(x: 72, y: 176, width: 42, height: 42), ctx: ctx)
        Text(s.provider.displayName, F.sf(30, 650), theme.ink).draw(x: 72 + 42 + 14, capCenter: 197, in: ctx)

        let big = Text(NumberFormat.tokens(s.tokens), F.sf(196, 750, tabular: true), theme.ink, kern: -10.8)
        big.draw(x: 64, baseline: baseline(top: 236, font: F.sf(196, 750), lineHeight: 168.6), in: ctx)
        Text(s.newOnly ? "new tokens in \(s.spanDuration)" : "tokens in \(s.spanDuration)", F.sf(28, 500), rgb(0xF4F4F6, 0.55))
            .draw(x: 72, baseline: baseline(top: 418, font: F.sf(28, 500)), in: ctx)
        if let c = s.costMicros {
            let cost = Text("≈ " + NumberFormat.dollars(micros: c, style: .precise), F.sf(40, 700, tabular: true), accent(s.provider), kern: -0.8)
            let b = baseline(top: 470, font: F.sf(40, 700))
            cost.draw(x: 72, baseline: b, in: ctx)
            Text("at API rates", F.sf(24, 500), rgb(0xF4F4F6, 0.5)).draw(x: 72 + cost.width + 12, baseline: b, in: ctx)
        }

        // Glass chart panel.
        let panel = CGRect(x: 1200 - 72 - 470, y: 150, width: 470, height: 372)
        glassPanel(panel, ctx: ctx)
        Text("TOKENS PER \(s.barUnit == "hr" ? "HOUR" : s.barUnit == "day" ? "DAY" : s.barUnit.uppercased())", F.sf(15, 700), rgb(0xF4F4F6, 0.45), kern: 1.8)
            .draw(x: panel.minX + 30, capCenter: panel.minY + 36, in: ctx)
        if let peak = s.bars.max(), peak > 0 {
            Text("peak \(NumberFormat.tokens(peak))/\(s.barUnit)", F.sf(22, 700, tabular: true), accent(s.provider))
                .draw(x: panel.maxX - 30, capCenter: panel.minY + 36, align: .right, in: ctx)
        }
        drawBars(s, rect: CGRect(x: panel.minX + 30, y: panel.minY + 76, width: panel.width - 60, height: 220), labelsTop: panel.minY + 314, ctx: ctx)

        // Footer band: composition and meter.
        let colW: CGFloat = (1200 - 144 - 56) / 2
        let lx: CGFloat = 72, rx: CGFloat = 72 + colW + 56
        compositionBar(s, rect: CGRect(x: lx, y: 566, width: colW, height: 12), ctx: ctx)
        var comp: [String] = []
        if !s.newOnly { comp.append("\(NumberFormat.percent(s.cachedShare)) cached") }
        comp += ["\(NumberFormat.percent(s.newShare)) new", "\(NumberFormat.percent(s.outputShare)) out"]
        Text(comp.joined(separator: " · "), F.sf(21, 500), rgb(0xF4F4F6, 0.55)).draw(x: lx, baseline: baseline(top: 566 + 12 + 14, font: F.sf(21, 500)), in: ctx)
        if let p = s.pace {
            shareMeter(p, rect: CGRect(x: rx, y: 560, width: colW, height: 40), ctx: ctx)
            let b = baseline(top: 560 + 40 + 12, font: F.sf(21, 600))
            Text("\(p.percentLeft)% of \(p.period) left", F.sf(21, 600), theme.ink).draw(x: rx, baseline: b, in: ctx)
            if let used = s.allowanceUsed {
                Text("≈ \(ShareBuilder.wholePercent(used)) used in \(s.spanDuration)", F.sf(21, 500), rgb(0xF4F4F6, 0.5))
                    .draw(x: rx + colW, baseline: b, align: .right, in: ctx)
            }
        }
        Text("local · read-only", F.sf(15, 600), rgb(0xF4F4F6, 0.3), kern: 0.6).draw(x: 72, baseline: 651, in: ctx)
    }

    private static func glassPanel(_ r: CGRect, ctx: CGContext) {
        let shape = rounded(r, 30)
        ctx.fillVertical(shape, white(0.07), white(0.025))
        ctx.innerStroke(shape, white(0.08), width: 1)
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            let ring = CGMutablePath(); ring.addPath(shape); ring.addPath(rounded(r.offsetBy(dx: 0, dy: 1), 30))
            ctx.addPath(ring); ctx.setFillColor(white(0.1).cgColor); ctx.fillPath(using: .evenOdd)
        }
    }

    private static func drawBars(_ s: ShareModel, rect: CGRect, labelsTop: CGFloat, ctx: CGContext) {
        let n = max(s.bars.count, 1)
        let gap: CGFloat = n > 12 ? 6 : 16
        let w = (rect.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let maxV = Double(max(s.bars.max() ?? 1, 1))
        let brand = Brand.of(s.provider)
        let top = s.provider == .claude ? rgb(0xF4AE92) : rgb(0x7FE3C4)
        let bottom = s.provider == .claude ? rgb(0xC3623F) : brand.deep
        let labelEvery = max(1, Int(ceil(Double(n) / 6)))
        for (i, v) in s.bars.enumerated() {
            let h = max(v > 0 ? 6 : 0, rect.height * CGFloat(Double(v) / maxV))
            let r = CGRect(x: rect.minX + CGFloat(i) * (w + gap), y: rect.maxY - h, width: w, height: h)
            if h > 0 {
                let shape = rounded(r, min(14, w / 2))
                ctx.withState { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: brand.base.alpha(0.25).cgColor); ctx.fill(shape, brand.base) }
                ctx.fillLinear(shape, [top, brand.base, bottom], from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.maxY), locations: [0, 0.7, 1])
                ctx.withState {
                    ctx.addPath(shape); ctx.clip()
                    let ring = CGMutablePath(); ring.addPath(shape); ring.addPath(rounded(r.offsetBy(dx: 0, dy: 1), min(14, w / 2)))
                    ctx.addPath(ring); ctx.setFillColor(white(0.45).cgColor); ctx.fillPath(using: .evenOdd)
                }
            }
            if i % labelEvery == 0, i < s.barLabels.count {
                Text(s.barLabels[i], F.sf(18, 600), rgb(0xF4F4F6, 0.42)).draw(x: r.midX, capCenter: labelsTop + 11, align: .center, in: ctx)
            }
        }
    }

    private static func compositionBar(_ s: ShareModel, rect: CGRect, ctx: CGContext) {
        let brand = Brand.of(s.provider)
        ctx.withState {
            ctx.addPath(rounded(rect, 6)); ctx.clip()
            let newW = max(26, rect.width * CGFloat(s.newShare)), outW = max(10, rect.width * CGFloat(s.outputShare))
            let cachedW = s.newOnly ? 0 : max(0, rect.width - newW - outW - 8)
            var x = rect.minX
            if cachedW > 0 {
                ctx.fillLinear(CGPath(rect: CGRect(x: x, y: rect.minY, width: cachedW, height: rect.height), transform: nil),
                               [brand.base.alpha(0.28), brand.base.alpha(0.5)], from: CGPoint(x: x, y: 0), to: CGPoint(x: x + cachedW, y: 0))
                x += cachedW + 4
            }
            let nw = s.newOnly ? rect.width * CGFloat(s.newShare / max(s.newShare + s.outputShare, 0.0001)) - 4 : newW
            ctx.fill(CGPath(rect: CGRect(x: x, y: rect.minY, width: nw, height: rect.height), transform: nil), brand.newInput)
            x += nw + 4
            ctx.fill(CGPath(rect: CGRect(x: x, y: rect.minY, width: s.newOnly ? rect.maxX - x : outW, height: rect.height), transform: nil), brand.deep)
        }
    }

    private static func shareMeter(_ p: ShareModel.Pace, rect: CGRect, ctx: CGContext) {
        let m = MeterModel(state: p.state, cells: p.cells, caret: nil, opacity: 1)
        MeterRenderer.draw(m, rect: rect, theme: theme, ctx: ctx, segmentHeight: 30, gap: 5, pad: 5, trackRadius: 20, endRadius: 15, innerRadius: 6, glow: 20)
    }

    // MARK: Copy Snapshot (both providers)

    static func drawSnapshot(_ shares: [ShareModel], ctx: CGContext) {
        background(nil, ctx: ctx)
        logo(ctx: ctx)
        if let first = shares.first { _ = chip(first.spanLong, right: 1200 - 72, midY: 88, ctx: ctx) }
        let n = max(shares.count, 1)
        let gap: CGFloat = 32
        let w = (1200 - 144 - gap * CGFloat(n - 1)) / CGFloat(n)
        for (i, s) in shares.enumerated() {
            let r = CGRect(x: 72 + CGFloat(i) * (w + gap), y: 160, width: w, height: 451)
            glassPanel(r, ctx: ctx)
            ctx.fillRadial(in: rounded(r, 30), center: r.origin, radii: CGSize(width: 420, height: 280), color: Brand.of(s.provider).base.alpha(0.3), fadeAt: 0.72)
            let x = r.minX + 36
            BrandMark.drawTile(s.provider, in: CGRect(x: x, y: r.minY + 34, width: 44, height: 44), ctx: ctx)
            let name = Text(s.provider.displayName, F.sf(30, 650), theme.ink)
            name.draw(x: x + 44 + 14, capCenter: r.minY + 56, in: ctx)
            if let plan = s.plan { _ = planPill(plan, provider: s.provider, right: r.maxX - 36, midY: r.minY + 56, ctx: ctx) }
            if let p = s.pace {
                let num = Text("\(p.percentLeft)", F.sf(120, 750, tabular: true), theme.ink, kern: -6)
                let b = baseline(top: r.minY + 112, font: F.sf(120, 750), lineHeight: 103)
                num.draw(x: x - 4, baseline: b, in: ctx)
                Text("%", F.sf(46, 650), theme.ink.alpha(0.88)).draw(x: x - 4 + num.width + 10, baseline: b - 120 * 0.7 + 46 * 0.7 + 4, in: ctx)
                Text("left this \(p.period) · \(p.renewCaption)", F.sf(21, 500), rgb(0xF4F4F6, 0.55)).draw(x: x, baseline: b + 40, in: ctx)
                shareMeter(p, rect: CGRect(x: x, y: r.minY + 290, width: w - 72, height: 40), ctx: ctx)
                ctx.withState {
                    ctx.translateBy(x: x, y: r.minY + 344)
                    ctx.scaleBy(x: 1.7, y: 1.7)
                    BadgeRenderer.draw(p.state.title, state: p.state, origin: .zero, theme: theme, ctx: ctx)
                }
            }
            var line = "\(NumberFormat.tokens(s.tokens)) tokens"
            if let c = s.costMicros { line += " · ≈ \(NumberFormat.dollars(micros: c, style: .precise))" }
            Text(line, F.sf(24, 650, tabular: true), accent(s.provider)).draw(x: x, baseline: r.maxY - 36, in: ctx)
        }
        Text("local · read-only", F.sf(15, 600), rgb(0xF4F4F6, 0.3), kern: 0.6).draw(x: 1200 - 72, baseline: 651, align: .right, in: ctx)
    }
}
