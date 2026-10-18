import AppKit
import HeadroomKit

/// The popover's fixed chrome: window surface, header (mark + tabs), Activity controls and footer.
@MainActor
enum PopoverChrome {
    static let width: CGFloat = 384
    static let pad: CGFloat = 12
    static let radius: CGFloat = 26
    static let headerHeight: CGFloat = 42
    static let footerHeight: CGFloat = 31

    static func drawWindow(_ rect: CGRect, theme: Theme, ctx: CGContext, opaque: Bool = true) {
        let shape = rounded(rect, radius)
        if opaque { ctx.fill(shape, theme.windowFill) }
        // Top sheen: radial-gradient(120% 45% at 50% 0%, sheen, transparent 60%)
        ctx.fillRadial(in: shape, center: CGPoint(x: rect.midX, y: rect.minY), radii: CGSize(width: rect.width * 1.2, height: rect.height * 0.45),
                       color: theme.windowSheen, fadeAt: 0.6)
        ctx.innerStroke(shape, theme.windowBorder, width: 1)
        if theme.isDark {
            ctx.withState {
                ctx.addPath(shape); ctx.clip()
                let ring = CGMutablePath(); ring.addPath(shape); ring.addPath(rounded(rect.offsetBy(dx: 0, dy: 1), radius))
                ctx.addPath(ring); ctx.setFillColor(white(0.08).cgColor); ctx.fillPath(using: .evenOdd)
            }
        }
    }

    /// Header row: app tile + wordmark, segmented Pace · Activity.
    static func drawHeader(x: CGFloat, y: CGFloat, width: CGFloat, title: String = "Headroom", tabs: [String]? = ["Pace", "Activity"], selected: Int, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let rowTop = y + 3, mid = rowTop + 14
        HeadroomMark.draw(in: CGRect(x: x + 3, y: mid - 13, width: 26, height: 26), ctx: ctx)
        Text(title, F.sf(16, 650), theme.ink, kern: -0.16).draw(x: x + 3 + 26 + 9, capCenter: mid, in: ctx)
        if let tabs {
            let seg = Segmented(items: tabs, selected: selected, font: F.sf(12, 600), padX: 12, height: 28)
            let r = CGRect(x: x + width - 3 - seg.width, y: mid - 14, width: seg.width, height: 28)
            seg.draw(in: r, theme: theme, ctx: ctx, out: out) { .tab($0) }
        }
    }

    static func drawFooter(_ f: FooterModel, x: CGFloat, y: CGFloat, width: CGFloat, theme: Theme, ctx: CGContext, out: RenderOutput?) {
        let mid = y + 11 + 7
        let color: NSColor = switch f.status { case .fresh: theme.ok; case .stale: theme.stale; case .error: theme.error }
        drawStatusDot(center: CGPoint(x: x + 6 + 3, y: mid), color: color, ctx: ctx)
        Text(f.text, F.sf(11.5, 500), theme.muted).draw(x: x + 6 + 12, capCenter: mid, in: ctx)
        let iconColor = theme.isDark ? rgb(0xF4F4F6, 0.55) : rgb(0x1C1C1E, 0.5)
        let gear = CGRect(x: x + width - 6 - 14, y: mid - 7, width: 14, height: 14)
        let refresh = gear.offsetBy(dx: -14 - 14, dy: 0)
        Glyph.refresh(in: refresh, color: iconColor, ctx: ctx)
        Glyph.gear(in: gear, color: iconColor, ctx: ctx)
        out?.add(refresh.insetBy(dx: -6, dy: -6), tooltip: "Refresh now", action: .refresh)
        out?.add(gear.insetBy(dx: -6, dy: -6), tooltip: "Settings", action: .settings)
    }
}

/// Segmented control (CSS `.sg`): recessed track with a raised selected segment.
struct Segmented {
    var items: [String]
    var selected: Int
    var font: NSFont
    var padX: CGFloat
    var height: CGFloat

    var segmentWidths: [CGFloat] { items.map { Text($0, font, .black).width + padX * 2 } }
    var width: CGFloat { segmentWidths.reduce(0, +) + 4 }

    func draw(in r: CGRect, theme: Theme, ctx: CGContext, out: RenderOutput?, action: (Int) -> HitRegion.Action) {
        let track = rounded(r, 10)
        ctx.fill(track, theme.segmentTrack)
        if theme.isDark { ctx.innerStroke(track, theme.segmentTrackBorder, width: 0.5) }
        var x = r.minX + 2
        for (i, item) in items.enumerated() {
            let w = segmentWidths[i]
            let seg = CGRect(x: x, y: r.minY + 2, width: w, height: r.height - 4)
            if i == selected {
                let s = rounded(seg, 8)
                ctx.withState {
                    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: (theme.isDark ? black(0.35) : black(0.12)).cgColor)
                    ctx.fill(s, theme.isDark ? rgb(0x2E2F34) : .white)
                }
                ctx.fillVertical(s, theme.segmentOnTop, theme.segmentOnBottom)
                if theme.isDark {
                    ctx.withState {
                        ctx.addPath(s); ctx.clip()
                        let ring = CGMutablePath(); ring.addPath(s); ring.addPath(rounded(seg.offsetBy(dx: 0, dy: 0.5), 8))
                        ctx.addPath(ring); ctx.setFillColor(white(0.2).cgColor); ctx.fillPath(using: .evenOdd)
                    }
                } else {
                    ctx.stroke(rounded(seg.insetBy(dx: -0.25, dy: -0.25), 8), black(0.04), width: 0.5)
                }
            }
            Text(item, font, theme.ink.fade(i == selected ? 1 : 0.5)).draw(x: seg.midX, capCenter: seg.midY, align: .center, in: ctx)
            out?.add(seg, action: action(i))
            x += w
        }
    }
}
