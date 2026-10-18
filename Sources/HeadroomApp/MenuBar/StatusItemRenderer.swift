import AppKit
import HeadroomKit

/// What the menu bar shows for one provider (PLAN §3.5). Hashable: it is the render key.
struct MenuBarProviderModel: Hashable {
    var provider: Provider
    var state: PacingState
    var cells: Int
    var hourglass: Bool
    /// Session warning ring + countdown ("48m") while the 5-hour session is ≥ 75%.
    var session: SessionWarning?
    /// Blocked (session/weekly/model cap at 100%, or major outage): ⏸ + countdown.
    var blockedCountdown: String?
    var fault: Bool
    var spoken: String

    struct SessionWarning: Hashable {
        var level: SessionLevel
        var used: Double
        var countdown: String
    }
}

enum MenuBarMode: String, CaseIterable, Codable, Sendable {
    case both, mostUrgent, claude, codex

    var title: String {
        switch self {
        case .both: "Both"
        case .mostUrgent: "Most urgent"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

@MainActor
enum StatusItemRenderer {
    static let height: CGFloat = 22

    struct Palette {
        let top: NSColor, bottom: NSColor, glow: NSColor
    }

    static func palette(_ s: PacingState, dark: Bool) -> Palette {
        switch (s, dark) {
        case (.plenty, true): Palette(top: rgb(0x9CCBFF), bottom: rgb(0x4A8EFF), glow: rgb(0x4A8EFF, 0.85))
        case (.plenty, false): Palette(top: rgb(0x64A8FF), bottom: rgb(0x2270F0), glow: rgb(0x2270F0, 0.35))
        case (.onPace, true): Palette(top: rgb(0xFFFFFF), bottom: rgb(0xD3D6DD), glow: white(0.45))
        case (.onPace, false): Palette(top: rgb(0x50535B), bottom: rgb(0x25272C), glow: black(0.18))
        case (.tight, true): Palette(top: rgb(0xFFDA7A), bottom: rgb(0xF4A51F), glow: rgb(0xF4A51F, 0.7))
        case (.tight, false): Palette(top: rgb(0xFFCB55), bottom: rgb(0xE99200), glow: rgb(0xE99200, 0.35))
        case (.veryTight, true): Palette(top: rgb(0xFF8FA2), bottom: rgb(0xEE3459), glow: rgb(0xEE3459, 0.75))
        case (.veryTight, false): Palette(top: rgb(0xFF6F86), bottom: rgb(0xDD2448), glow: rgb(0xDD2448, 0.35))
        }
    }

    // MARK: Layout

    static func width(_ items: [MenuBarProviderModel]) -> CGFloat {
        guard !items.isEmpty else { return 22 }
        return items.map(groupWidth).reduce(0, +) + CGFloat(items.count - 1) * 12 + 4
    }

    static let meterWidth: CGFloat = 1.5 + 5 * 6 + 4 * 1.5 + 1.5

    static func groupWidth(_ m: MenuBarProviderModel) -> CGFloat {
        var w: CGFloat = 14 + 5 + meterWidth
        if m.hourglass && m.blockedCountdown == nil { w += 5 + 7 }
        if let b = m.blockedCountdown { w += 5 + 7 + 3 + countdownText(b, color: .black).width }
        else if let s = m.session { w += 5 + 3 + 11 + 3 + countdownText(s.countdown, color: .black).width }
        if m.fault { w += 4 + 9 }
        return ceil(w)
    }

    static func countdownText(_ s: String, color: NSColor) -> Text { Text(s, F.sf(11.5, 650, tabular: true), color) }

    // MARK: Image

    /// A non-template image that redraws itself for the current menu bar appearance.
    static func image(_ items: [MenuBarProviderModel]) -> NSImage {
        let size = NSSize(width: width(items), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            draw(items, in: rect, dark: dark, ctx: ctx)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = items.map(\.spoken).joined(separator: " ")
        return image
    }

    static func draw(_ items: [MenuBarProviderModel], in rect: CGRect, dark: Bool, ctx: CGContext) {
        let ink: NSColor = dark ? .white : rgb(0x1C1C1E)
        let mid = rect.midY
        var x = rect.minX + 2
        if items.isEmpty {
            HeadroomMark.draw(in: CGRect(x: x, y: mid - 8, width: 16, height: 16), ctx: ctx, dropShadow: false)
            return
        }
        for (i, m) in items.enumerated() {
            if i > 0 { x += 12 }
            let dim: CGFloat = m.blockedCountdown != nil ? 0.4 : (m.fault ? 0.5 : 1)
            // Brand mark: Claude clay, OpenAI in the label color.
            let markColor: NSColor = m.provider == .claude ? (dark ? rgb(0xE8956F) : rgb(0xD97757)) : ink
            BrandMark.draw(m.provider, in: CGRect(x: x, y: mid - 7, width: 14, height: 14), color: markColor, ctx: ctx)
            x += 14 + 5
            // Micro meter.
            let track = CGRect(x: x, y: mid - 7, width: meterWidth, height: 14)
            ctx.fill(rounded(track, 4), dark ? black(0.25) : black(0.05))
            let p = palette(m.state, dark: dark)
            ctx.withState {
                ctx.setAlpha(dim)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for c in 0..<5 {
                    let r = CGRect(x: x + 1.5 + CGFloat(c) * 7.5, y: mid - 5.5, width: 6, height: 11)
                    let shape = rounded(r, 1.5)
                    if c < m.cells {
                        ctx.glow(shape, color: p.glow, blur: 4, base: p.bottom)
                        ctx.fillVertical(shape, p.top, p.bottom)
                    } else {
                        ctx.fill(shape, dark ? white(0.16) : black(0.13))
                    }
                }
                ctx.endTransparencyLayer()
            }
            x += meterWidth
            if let blocked = m.blockedCountdown {
                x += 5
                let c = dark ? rgb(0xFF8FA2) : rgb(0xD21F45)
                Glyph.pause(in: CGRect(x: x, y: mid - 4.5, width: 7, height: 9), color: c, ctx: ctx)
                x += 7 + 3
                let t = countdownText(blocked, color: c)
                t.draw(x: x, capCenter: mid, in: ctx)
                x += t.width
            } else {
                if m.hourglass {
                    x += 5
                    Glyph.hourglass(in: CGRect(x: x, y: mid - 5, width: 7, height: 10), color: dark ? rgb(0x9CCBFF) : rgb(0x1F6FEB), ctx: ctx)
                    x += 7
                }
                if let s = m.session {
                    x += 5 + 3
                    let c: NSColor = s.level == .amber ? (dark ? rgb(0xFFC248) : rgb(0xB87200)) : (dark ? rgb(0xFF8FA2) : rgb(0xD21F45))
                    Glyph.ring(in: CGRect(x: x, y: mid - 5.5, width: 11, height: 11), fraction: CGFloat(s.used), color: c,
                               track: c.fade(0.22), lineWidth: 2, ctx: ctx)
                    x += 11 + 3
                    let t = countdownText(s.countdown, color: c)
                    t.draw(x: x, capCenter: mid, in: ctx)
                    x += t.width
                }
            }
            if m.fault {
                x += 4
                Glyph.fault(in: CGRect(x: x, y: mid - 4.5, width: 9, height: 9), color: ink.fade(0.7), ctx: ctx)
                x += 9
            }
        }
    }
}
