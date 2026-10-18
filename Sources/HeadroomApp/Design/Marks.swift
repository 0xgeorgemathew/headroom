import AppKit
import HeadroomKit

/// The real Claude and OpenAI marks, read from `assets/brand/*.svg` (copied into the app's
/// Resources by `make app`). 24×24 viewBox.
@MainActor
enum BrandMark {
    private static var cache: [Provider: CGPath] = [:]

    static func path(_ provider: Provider) -> CGPath {
        if let p = cache[provider] { return p }
        let name = provider == .claude ? "claude" : "openai"
        let p = loadPathData(name).map(SVGPath.parse) ?? CGMutablePath()
        cache[provider] = p
        return p
    }

    private static func loadPathData(_ name: String) -> String? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "brand") { candidates.append(u) }
        // Development runs (`swift run`): read straight from the repository.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("assets/brand/\(name).svg"))
        for url in candidates {
            guard let svg = try? String(contentsOf: url, encoding: .utf8),
                  let r = svg.range(of: #"\sd="([^"]+)""#, options: .regularExpression) else { continue }
            let attr = svg[r]
            return String(attr.dropFirst(4).dropLast())
        }
        return nil
    }

    /// Draws the mark filling `rect` (square) in `color`.
    static func draw(_ provider: Provider, in rect: CGRect, color: NSColor, ctx: CGContext) {
        let s = rect.width / 24
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s)
        guard let scaled = path(provider).copy(using: &t) else { return }
        ctx.fill(scaled, color)
    }

    /// App-icon-style provider tile (PLAN §3.1): brand gradient squircle with the mark inside.
    static func drawTile(_ provider: Provider, in rect: CGRect, ctx: CGContext, shadow: Bool = true) {
        let brand = Brand.of(provider)
        let r = rect.width * 0.29
        let shape = rounded(rect, r)
        if shadow {
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * rect.width / 28), blur: 6 * rect.width / 28, color: black(0.22).cgColor)
                ctx.fill(shape, brand.tileBottom)
            }
        }
        // CSS linear-gradient(150deg, top, bottom): from top-left-ish to bottom-right-ish.
        let a = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY), b = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        ctx.fillLinear(shape, [brand.tileTop, brand.tileBottom], from: a, to: b)
        // inset 0 1px 0 rgba(255,255,255,.3), inset 0 0 0 .5px rgba(255,255,255,.14)
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            let top = rounded(rect.offsetBy(dx: 0, dy: 1), r)
            let outer = CGMutablePath(); outer.addPath(shape); outer.addPath(top)
            ctx.addPath(outer)
            ctx.setFillColor(white(0.3).cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.innerStroke(shape, white(0.14), width: 0.5)
        let markSide = rect.width * (provider == .claude ? 0.62 : 0.60)
        let m = CGRect(x: rect.midX - markSide / 2, y: rect.midY - markSide / 2, width: markSide, height: markSide)
        draw(provider, in: m, color: brand.markInk, ctx: ctx)
    }
}

/// The Headroom meter-H (`assets/icon.svg`), drawn natively so the glow survives at any size.
enum HeadroomMark {
    static let cellColors: [UInt32] = [0x4A8EFF, 0x7DB4FF, 0xECEDF1, 0xFFC248, 0xFF6982]

    /// Draws the full app-icon tile into `rect` (square). 64-unit geometry from the SVG.
    static func draw(in rect: CGRect, ctx: CGContext, dropShadow: Bool = true) {
        let s = rect.width / 64
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        let bg = rounded(R(0, 0, 64, 64), 15 * s)
        if dropShadow {
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * s * 64 / 26), blur: 5 * s * 64 / 26, color: black(0.25).cgColor)
                ctx.fill(bg, rgb(0x1A1C22))
            }
        }
        ctx.fillLinear(bg, [rgb(0x2E313B), rgb(0x0E0F13)], from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.stroke(rounded(R(0.5, 0.5, 63, 63), 14.5 * s), white(0.12), width: max(s, 0.5))

        var lit: [(CGRect, NSColor)] = []
        var ghost: [(CGRect, NSColor)] = []
        for x in [16.0, 38.0] {
            for i in 0..<5 {
                let y = 51.8 - 6.2 - 8.7 * Double(i)
                let cell = (R(x, y, 10, 6.2), rgb(cellColors[i]))
                if i < 3 { lit.append(cell) } else { ghost.append(cell) }
            }
        }
        // Glow: blurred copy of the lit cells at 55% (feGaussianBlur stdDeviation 1.8).
        ctx.withState {
            ctx.setAlpha(0.55)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for (r, c) in lit {
                ctx.setShadow(offset: .zero, blur: 1.8 * 2 * s, color: c.cgColor)
                ctx.fill(rounded(r, 2.6 * s), c)
            }
            ctx.endTransparencyLayer()
        }
        for (r, c) in lit { ctx.fill(rounded(r, 2.6 * s), c) }
        ctx.fill(rounded(R(24, 28.8, 16, 5), 2.2 * s), rgb(0xECEDF1))
        for (r, c) in ghost { ctx.fill(rounded(r, 2.6 * s), c.alpha(0.27)) }
    }
}
