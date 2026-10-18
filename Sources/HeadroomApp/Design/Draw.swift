import AppKit

// MARK: - Fonts

/// Font helpers mirroring the mockup's CSS weights (SF is variable, so in-between weights are real).
enum F {
    static func weight(_ css: Int) -> NSFont.Weight {
        switch css {
        case ..<450: .regular
        case ..<550: .medium
        case ..<625: .semibold
        case ..<675: NSFont.Weight(rawValue: 0.35)
        case ..<725: .bold
        case ..<775: NSFont.Weight(rawValue: 0.48)
        default: .heavy
        }
    }

    /// Fonts are cached: each new NSFont instance carries its own CoreText glyph caches, and the
    /// popover draws hundreds of runs per pass.
    nonisolated(unsafe) private static var cache: [Int: NSFont] = [:]
    private static let lock = NSLock()

    private static func cached(_ key: Int, _ make: () -> NSFont) -> NSFont {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = make()
        cache[key] = f
        return f
    }

    /// SF Pro (the system font picks Text or Display optics by size).
    static func sf(_ size: CGFloat, _ css: Int = 400, tabular: Bool = false) -> NSFont {
        cached(Int(size * 100) * 10_000 + css * 10 + (tabular ? 1 : 0)) {
            let base = NSFont.systemFont(ofSize: size, weight: weight(css))
            return tabular ? base.tabular : base
        }
    }

    static func mono(_ size: CGFloat, _ css: Int = 400) -> NSFont {
        cached(-(Int(size * 100) * 10_000 + css * 10)) { NSFont.monospacedSystemFont(ofSize: size, weight: weight(css)) }
    }
}

extension NSFont {
    /// Same font with tabular (monospaced) figures.
    var tabular: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Text

/// A single run of styled text that can be measured and drawn at its top-left or baseline.
struct Text {
    var string: NSAttributedString

    init(_ s: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        string = NSAttributedString(string: s, attributes: attributes)
    }

    init(_ parts: [Text]) {
        let m = NSMutableAttributedString()
        for p in parts { m.append(p.string) }
        string = m
    }

    /// Typographic width (excludes the trailing kern CSS doesn't add either).
    var width: CGFloat {
        let line = CTLineCreateWithAttributedString(string)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    var font: NSFont { string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12) }

    /// Cap height of the first run's font, for optical vertical centering.
    var capHeight: CGFloat { font.capHeight }

    /// Draws with the baseline at `y` in a flipped (top-left origin) context.
    func draw(x: CGFloat, baseline y: CGFloat, align: NSTextAlignment = .left, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let originX: CGFloat = switch align {
        case .right: x - w
        case .center: x - w / 2
        default: x
        }
        ctx.saveGState()
        // Core Text draws in an unflipped space; flip locally around the baseline.
        ctx.textMatrix = .identity
        ctx.translateBy(x: originX, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Draws so the cap-height box is vertically centered on `midY`.
    func draw(x: CGFloat, capCenter midY: CGFloat, align: NSTextAlignment = .left, in ctx: CGContext) {
        draw(x: x, baseline: midY + capHeight / 2, align: align, in: ctx)
    }
}

// MARK: - Geometry

/// Shared date formatters by locale + template (DateFormatter is expensive to create).
enum Formatters {
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func template(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)|\(calendar.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }
}

extension CGRect {
    func inset(_ d: CGFloat) -> CGRect { insetBy(dx: d, dy: d) }
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let rad = min(radius, min(r.width, r.height) / 2)
    return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

/// Rounded rect with separate left/right corner radii (meter end segments).
func rounded(_ r: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
    let l = min(left, r.height / 2, r.width / 2), rr = min(right, r.height / 2, r.width / 2)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + l, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rr), radius: rr)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rr, y: r.maxY), radius: rr)
    p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - l), radius: l)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + l))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + l, y: r.minY), radius: l)
    p.closeSubpath()
    return p
}

/// Rounded rect with only the top corners rounded.
func roundedTop(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let rad = min(radius, r.width / 2, r.height)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    return p
}

// MARK: - Painting

extension CGContext {
    func fill(_ path: CGPath, _ color: NSColor) {
        saveGState()
        addPath(path)
        setFillColor(color.cgColor)
        fillPath()
        restoreGState()
    }

    func stroke(_ path: CGPath, _ color: NSColor, width: CGFloat, dash: [CGFloat]? = nil, cap: CGLineCap = .butt, join: CGLineJoin = .miter) {
        saveGState()
        addPath(path)
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        setLineCap(cap)
        setLineJoin(join)
        if let dash { setLineDash(phase: 0, lengths: dash) }
        strokePath()
        restoreGState()
    }

    /// Strokes a hairline just inside the path's edge (CSS `inset 0 0 0 1px`).
    func innerStroke(_ path: CGPath, _ color: NSColor, width: CGFloat = 1) {
        saveGState()
        addPath(path)
        clip()
        addPath(path)
        setStrokeColor(color.cgColor)
        setLineWidth(width * 2)
        strokePath()
        restoreGState()
    }

    /// Linear gradient fill clipped to `path`. Points are in user space.
    func fillLinear(_ path: CGPath, _ colors: [NSColor], from a: CGPoint, to b: CGPoint, locations: [CGFloat]? = nil) {
        saveGState()
        addPath(path)
        clip()
        if let g = gradient(colors, locations) {
            drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        restoreGState()
    }

    /// Vertical gradient over the path's bounding box.
    func fillVertical(_ path: CGPath, _ top: NSColor, _ bottom: NSColor) {
        let b = path.boundingBox
        fillLinear(path, [top, bottom], from: CGPoint(x: b.midX, y: b.minY), to: CGPoint(x: b.midX, y: b.maxY))
    }

    /// Elliptical radial wash (CSS `radial-gradient(w h at x y, color, transparent stop)`).
    func fillRadial(in clipPath: CGPath, center: CGPoint, radii: CGSize, color: NSColor, fadeAt: CGFloat = 1) {
        saveGState()
        addPath(clipPath)
        clip()
        translateBy(x: center.x, y: center.y)
        scaleBy(x: 1, y: radii.height / max(radii.width, 0.001))
        if let g = gradient([color, color.withAlphaComponent(0)], [0, fadeAt]) {
            drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radii.width, options: [])
        }
        restoreGState()
    }

    /// Fills `path` with `base` and a soft outer glow (CSS `box-shadow: 0 0 blur color`).
    /// Draw the real (gradient) fill on top afterwards; the zero offset keeps this correct
    /// regardless of the backing scale.
    func glow(_ path: CGPath, color: NSColor, blur: CGFloat, base: NSColor) {
        saveGState()
        setShadow(offset: .zero, blur: blur, color: color.cgColor)
        addPath(path)
        setFillColor(base.cgColor)
        fillPath()
        restoreGState()
    }

    /// Strokes `path` with a blurred halo (chart line glow copy).
    func glowStroke(_ path: CGPath, color: NSColor, width: CGFloat, blur: CGFloat) {
        saveGState()
        setShadow(offset: .zero, blur: blur, color: color.cgColor)
        addPath(path)
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        setLineCap(.round)
        setLineJoin(.round)
        strokePath()
        restoreGState()
    }

    func gradient(_ colors: [NSColor], _ locations: [CGFloat]?) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors.map { $0.usingColorSpace(.sRGB)?.cgColor ?? $0.cgColor } as CFArray,
            locations: locations
        )
    }

    func withState(_ body: () -> Void) {
        saveGState()
        body()
        restoreGState()
    }
}

extension NSColor {
    func alpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }

    /// Multiplies the existing alpha.
    func fade(_ f: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return c.withAlphaComponent(c.alphaComponent * f)
    }

    /// CSS `color-mix(in srgb, self p%, transparent)`.
    func mixTransparent(_ p: CGFloat) -> NSColor { fade(p) }
}

/// Catmull-Rom smoothing to cubic Béziers (the mockup's `smooth()`).
func smoothPath(_ pts: [CGPoint]) -> CGMutablePath {
    let p = CGMutablePath()
    guard let first = pts.first else { return p }
    p.move(to: first)
    guard pts.count > 1 else { return p }
    for i in 0..<(pts.count - 1) {
        let p0 = i > 0 ? pts[i - 1] : pts[i]
        let p1 = pts[i], p2 = pts[i + 1]
        let p3 = i + 2 < pts.count ? pts[i + 2] : p2
        p.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
    return p
}
