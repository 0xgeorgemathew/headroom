import AppKit

/// Small vector glyphs used across the popover, menu bar and share card. Each draws into a
/// rect using the mockup's viewBox geometry, scaled.
enum Glyph {
    private static func transform(_ rect: CGRect, viewBox: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / viewBox.width, y: rect.height / viewBox.height)
    }

    nonisolated(unsafe) private static var parsed: [String: CGPath] = [:]
    private static let lock = NSLock()

    /// Parsed once per path string, then transformed into place.
    private static func svg(_ d: String, _ rect: CGRect, _ vb: CGSize) -> CGPath {
        var t = transform(rect, viewBox: vb)
        lock.lock()
        let base = parsed[d] ?? {
            let p = SVGPath.parse(d)
            parsed[d] = p
            return p
        }()
        lock.unlock()
        return base.copy(using: &t) ?? CGMutablePath()
    }

    /// Hourglass, 14×20 viewBox (rect height h, width 0.7h).
    static func hourglass(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let vb = CGSize(width: 14, height: 20), k = rect.height / 20
        ctx.stroke(svg("M2 1.6h10M2 18.4h10", rect, vb), color, width: 2.2 * k, cap: .round)
        ctx.stroke(svg("M3.3 2.2c0 4 3.7 5.4 3.7 7.8s-3.7 3.8-3.7 7.8M10.7 2.2c0 4-3.7 5.4-3.7 7.8s3.7 3.8 3.7 7.8", rect, vb), color, width: 1.7 * k)
        ctx.fill(svg("M4.4 17.4c.7-2 2.6-2.9 2.6-2.9s1.9.9 2.6 2.9z", rect, vb), color)
        ctx.fill(svg("M5.2 5.6h3.6c-.6 1.2-1.8 1.9-1.8 1.9s-1.2-.7-1.8-1.9z", rect, vb), color)
    }

    /// Progress ring starting at 12 o'clock, clockwise. `lineWidth` defaults to the mockup's 2.4.
    static func ring(in rect: CGRect, fraction: CGFloat, color: NSColor, track: NSColor, lineWidth: CGFloat = 2.4, ctx: CGContext) {
        let r = rect.width / 2 - lineWidth * 2 / 3
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let circle = CGMutablePath()
        circle.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.stroke(circle, track, width: lineWidth)
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return }
        let arc = CGMutablePath()
        // Flipped context: increasing angle runs clockwise on screen.
        arc.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * f, clockwise: false)
        ctx.stroke(arc, color, width: lineWidth, cap: .round)
    }

    /// Dollar coin glyph, 16×16 viewBox.
    static func coin(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let p = svg("M10.4 5.4c-.4-.8-1.3-1.2-2.4-1.2-1.4 0-2.3.7-2.3 1.7 0 2.4 4.9 1.3 4.9 3.9 0 1.1-1 1.8-2.5 1.8-1.3 0-2.2-.6-2.6-1.4M8 2.6v1.6m0 7.6v1.6", rect, CGSize(width: 16, height: 16))
        ctx.stroke(p, color, width: 1.6 * rect.width / 16, cap: .round)
    }

    static func calendar(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let vb = CGSize(width: 16, height: 16), k = rect.width / 16
        ctx.stroke(svg("M4.4 2.8h7.2a2.6 2.6 0 0 1 2.6 2.6v6.2a2.6 2.6 0 0 1-2.6 2.6H4.4a2.6 2.6 0 0 1-2.6-2.6V5.4a2.6 2.6 0 0 1 2.6-2.6z", rect, vb), color, width: 1.5 * k)
        ctx.stroke(svg("M1.8 6.6h12.4M5.2 1.4v2.8M10.8 1.4v2.8", rect, vb), color, width: 1.5 * k, cap: .round)
    }

    static func refresh(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let vb = CGSize(width: 16, height: 16), k = rect.width / 16
        ctx.stroke(svg("M13.2 6.2A5.6 5.6 0 1 0 13.6 9", rect, vb), color, width: 1.6 * k, cap: .round)
        ctx.stroke(svg("M13.8 2.2v4.2H9.6", rect, vb), color, width: 1.6 * k, cap: .round, join: .round)
    }

    static func gear(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let k = rect.width / 16
        let p = CGMutablePath()
        let n = 8, outer: CGFloat = 6.6, inner: CGFloat = 5.1
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (8 + cos(a) * r) * k, y: rect.minY + (8 + sin(a) * r) * k) }
        for i in 0..<(n * 2) {
            let a0 = CGFloat(i) / CGFloat(n * 2) * 2 * .pi - .pi / 2
            let a1 = CGFloat(i + 1) / CGFloat(n * 2) * 2 * .pi - .pi / 2
            let r = i % 2 == 1 ? inner : outer
            if i == 0 { p.move(to: pt(a0 + 0.08, r)) } else { p.addLine(to: pt(a0 + 0.08, r)) }
            p.addLine(to: pt(a1 - 0.08, r))
        }
        p.closeSubpath()
        ctx.stroke(p, color, width: 1.4 * k, join: .round)
        let hub = CGMutablePath()
        hub.addEllipse(in: CGRect(x: rect.minX + (8 - 2.1) * k, y: rect.minY + (8 - 2.1) * k, width: 4.2 * k, height: 4.2 * k))
        ctx.stroke(hub, color, width: 1.4 * k)
    }

    /// Pause bars, 8×9 viewBox; rect height = h.
    static func pause(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let k = rect.height / 9
        ctx.fill(rounded(CGRect(x: rect.minX + 1 * k, y: rect.minY, width: 2.2 * k, height: 9 * k), 0.9 * k), color)
        ctx.fill(rounded(CGRect(x: rect.minX + 4.8 * k, y: rect.minY, width: 2.2 * k, height: 9 * k), 0.9 * k), color)
    }

    /// Four-point spark (early reset), 10×10 viewBox.
    static func spark(in rect: CGRect, color: NSColor, ctx: CGContext) {
        ctx.fill(svg("M5 0c.4 2.6 1.4 3.6 5 5-3.6 1.4-4.6 2.4-5 5-.4-2.6-1.4-3.6-5-5 3.6-1.4 4.6-2.4 5-5z", rect, CGSize(width: 10, height: 10)), color)
    }

    /// Warning triangle with an inked exclamation, 16×16 viewBox.
    static func warning(in rect: CGRect, fill: NSColor, ink: NSColor, ctx: CGContext) {
        let vb = CGSize(width: 16, height: 16), k = rect.width / 16
        let tri = svg("M8 1.8 15 14.2H1z", rect, vb)
        ctx.fill(tri, fill)
        ctx.stroke(tri, fill, width: 1.8 * k, join: .round)
        ctx.stroke(svg("M8 6.2v3.4", rect, vb), ink, width: 1.8 * k, cap: .round)
        let dot = CGMutablePath()
        dot.addEllipse(in: CGRect(x: rect.minX + 7 * k, y: rect.minY + 11 * k, width: 2 * k, height: 2 * k))
        ctx.fill(dot, ink)
    }

    /// Upward caret, 7×5.
    static func caret(in rect: CGRect, color: NSColor, ctx: CGContext) {
        ctx.fill(svg("M3.5 0 7 5H0z", rect, CGSize(width: 7, height: 5)), color)
    }

    /// Small "no connection" fault glyph for the menu bar (a slashed circle).
    static func fault(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let k = rect.width / 10
        let c = CGMutablePath()
        c.addEllipse(in: rect.insetBy(dx: 0.9 * k, dy: 0.9 * k))
        ctx.stroke(c, color, width: 1.4 * k)
        let s = CGMutablePath()
        s.move(to: CGPoint(x: rect.minX + 2.6 * k, y: rect.maxY - 2.6 * k))
        s.addLine(to: CGPoint(x: rect.maxX - 2.6 * k, y: rect.minY + 2.6 * k))
        ctx.stroke(s, color, width: 1.4 * k, cap: .round)
    }

    static func chevronDown(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.25))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.3))
        ctx.fill(p, color)
    }
}
