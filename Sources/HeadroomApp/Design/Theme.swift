import AppKit
import HeadroomKit

/// sRGB color from a hex literal, e.g. `rgb(0xD97757)`.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

/// Design tokens (PLAN §3.3), resolved for one appearance.
struct Theme: Sendable {
    let isDark: Bool

    static let dark = Theme(isDark: true)
    static let light = Theme(isDark: false)

    static func current(for appearance: NSAppearance) -> Theme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    // MARK: Text

    var ink: NSColor { isDark ? rgb(0xF4F4F6) : rgb(0x1C1C1E) }
    var muted: NSColor { isDark ? rgb(0xF4F4F6, 0.58) : rgb(0x1C1C1E, 0.55) }
    var muted2: NSColor { isDark ? rgb(0xF4F4F6, 0.40) : rgb(0x1C1C1E, 0.40) }
    var faint: NSColor { isDark ? rgb(0xF4F4F6, 0.30) : rgb(0x1C1C1E, 0.30) }

    // MARK: Surfaces

    var windowFill: NSColor { isDark ? rgb(0x131418) : rgb(0xEDEDF1) }
    var windowSheen: NSColor { isDark ? white(0.05) : white(1) }
    var windowBorder: NSColor { isDark ? white(0.09) : black(0.07) }

    var cardTop: NSColor { isDark ? white(0.058) : white(1) }
    var cardBottom: NSColor { isDark ? white(0.03) : white(1) }
    var cardBorder: NSColor { isDark ? white(0.075) : black(0.05) }
    var cardHighlight: NSColor { isDark ? white(0.07) : .clear }
    /// Opaque approximation of the card surface, used where shapes need a "hole" (chart dots).
    var cardSolid: NSColor { isDark ? rgb(0x202125) : rgb(0xFFFFFF) }

    var groupFill: NSColor { isDark ? black(0.20) : black(0.035) }
    var groupBorder: NSColor { isDark ? white(0.07) : black(0.04) }
    var separator: NSColor { isDark ? white(0.07) : black(0.06) }

    var segmentTrack: NSColor { isDark ? white(0.06) : black(0.05) }
    var segmentTrackBorder: NSColor { isDark ? white(0.06) : .clear }
    var segmentOnTop: NSColor { isDark ? white(0.17) : white(1) }
    var segmentOnBottom: NSColor { isDark ? white(0.10) : white(1) }

    var meterTrack: NSColor { isDark ? black(0.30) : black(0.06) }
    var meterTrackBorder: NSColor { isDark ? white(0.06) : .clear }
    var meterEmpty: NSColor { isDark ? white(0.055) : white(0.7) }

    var chartGrid: NSColor { isDark ? white(0.05) : black(0.05) }
    var chartBaseline: NSColor { isDark ? white(0.05) : black(0.10) }
    var chartLabel: NSColor { isDark ? rgb(0xF4F4F6, 0.42) : rgb(0x1C1C1E, 0.42) }
    var chartPill: NSColor { isDark ? white(0.10) : black(0.06) }
    var chartDash: NSColor { isDark ? rgb(0xF4F4F6, 0.30) : rgb(0x1C1C1E, 0.28) }

    var chipFill: NSColor { isDark ? white(0.06) : black(0.045) }
    var chipBorder: NSColor { isDark ? white(0.07) : black(0.04) }
    var tileFill: NSColor { isDark ? white(0.045) : black(0.035) }

    var ok: NSColor { rgb(0x30D158) }
    var okHalo: NSColor { rgb(0x30D158, 0.16) }
    var stale: NSColor { rgb(0xFFB020) }
    var error: NSColor { isDark ? rgb(0xFF6982) : rgb(0xD21F45) }

    var amber: NSColor { isDark ? rgb(0xFFC248) : rgb(0xB87200) }
    var rose: NSColor { isDark ? rgb(0xFF6982) : rgb(0xD21F45) }
    var azure: NSColor { isDark ? rgb(0x6AA8FF) : rgb(0x1F6FEB) }
    var azureLight: NSColor { isDark ? rgb(0x8CC2FF) : rgb(0x2270F0) }

    // MARK: Pacing (PLAN §3.3)

    func pacing(_ state: PacingState) -> PacingColors {
        switch (state, isDark) {
        case (.plenty, true):
            PacingColors(top: rgb(0x8CC2FF), bottom: rgb(0x4A8EFF), glow: rgb(0x4A8EFF, 0.55), text: rgb(0x6AA8FF))
        case (.plenty, false):
            PacingColors(top: rgb(0x64A8FF), bottom: rgb(0x2270F0), glow: rgb(0x2270F0, 0.30), text: rgb(0x1F6FEB))
        case (.onPace, true):
            PacingColors(top: rgb(0xFFFFFF), bottom: rgb(0xD3D6DD), glow: white(0.28), text: rgb(0xECEDF1))
        case (.onPace, false):
            PacingColors(top: rgb(0x50535B), bottom: rgb(0x25272C), glow: black(0.16), text: rgb(0x2A2C31))
        case (.tight, true):
            PacingColors(top: rgb(0xFFDA7A), bottom: rgb(0xF4A51F), glow: rgb(0xF4A51F, 0.50), text: rgb(0xFFC248))
        case (.tight, false):
            PacingColors(top: rgb(0xFFCB55), bottom: rgb(0xE99200), glow: rgb(0xE99200, 0.30), text: rgb(0xB87200))
        case (.veryTight, true):
            PacingColors(top: rgb(0xFF8FA2), bottom: rgb(0xEE3459), glow: rgb(0xEE3459, 0.55), text: rgb(0xFF6982))
        case (.veryTight, false):
            PacingColors(top: rgb(0xFF6F86), bottom: rgb(0xDD2448), glow: rgb(0xDD2448, 0.30), text: rgb(0xD21F45))
        }
    }

    func session(_ level: SessionLevel) -> NSColor {
        switch level {
        case .normal: ink
        case .amber: amber
        case .rose, .blocked: rose
        }
    }
}

struct PacingColors: Sendable {
    let top: NSColor
    let bottom: NSColor
    let glow: NSColor
    /// Text, dot and chart line color.
    let text: NSColor
}

/// Brand identity colors (PLAN §3.3). Identity only, never a pacing state.
struct Brand: Sendable {
    let base: NSColor
    let light: NSColor
    let deep: NSColor
    /// Activity "new input" segment color.
    let newInput: NSColor
    let tileTop: NSColor
    let tileBottom: NSColor
    let markInk: NSColor
    let orbDark: NSColor
    let orbLight: NSColor

    static let claude = Brand(
        base: rgb(0xD97757), light: rgb(0xF0A084), deep: rgb(0x9E4A2F), newInput: rgb(0xE58A6B),
        tileTop: rgb(0xE8956F), tileBottom: rgb(0xC65F3C), markInk: rgb(0xFFF6EF),
        orbDark: rgb(0xD97757, 0.27), orbLight: rgb(0xD97757, 0.12)
    )
    static let codex = Brand(
        base: rgb(0x10A37F), light: rgb(0x3FD0A3), deep: rgb(0x07664F), newInput: rgb(0x2FB78F),
        tileTop: rgb(0x22C496), tileBottom: rgb(0x0A7D61), markInk: rgb(0xFFFFFF),
        orbDark: rgb(0x10A37F, 0.22), orbLight: rgb(0x10A37F, 0.10)
    )

    static func of(_ provider: Provider) -> Brand { provider == .claude ? .claude : .codex }

    /// Plan pill text color (lighter on dark, darker on light).
    func pillText(_ theme: Theme) -> NSColor {
        theme.isDark ? light : base.blended(withFraction: 0.2, of: .black) ?? base
    }
}
