import AppKit
import HeadroomKit

/// The right half of Settings: the welcome window's wallpaper stage, showing what the current
/// section changes. Drawn with the live renderers, so every preview is exact.
@MainActor
enum SettingsStage {
    static func draw(_ section: SettingsView.Section, rect: CGRect, settings: AppSettings, model: AppModel?, theme t: Theme, ctx: CGContext) {
        let shape = rounded(rect, 18)
        OnboardingStage.drawWallpaper(shape, rect: rect, theme: t, ctx: ctx)
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            switch section {
            case .general: OnboardingStage.providers(rect, settings: settings, theme: t, ctx: ctx)
            case .menuBar: OnboardingStage.menuBar(rect, settings: settings, theme: t, ctx: ctx)
            case .card: card(rect, settings: settings, theme: t, ctx: ctx)
            case .session: OnboardingStage.session(rect, settings: settings, theme: t, ctx: ctx)
            case .notifications: notifications(rect, settings: settings, theme: t, ctx: ctx)
            case .advanced: terminal(rect, theme: t, ctx: ctx)
            }
        }
        ctx.innerStroke(shape, t.isDark ? white(0.08) : black(0.06), width: 1)
    }

    /// A Claude card with the chosen meters and graphs, scaled to fit.
    private static func card(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        var presenter = Presenter(now: Demo.now, policy: settings.policy, options: settings.presentation)
        presenter.locale = Display.locale
        var input = Demo.claudeMockup(now: Demo.now)
        input.weekCostMicros = nil
        let model = presenter.paceCard(input)
        let width = PopoverChrome.width - PopoverChrome.pad * 2
        let height = PaceCardRenderer.draw(model, origin: .zero, width: width, theme: t, ctx: nil)
        let room = CGRect(x: rect.minX + 18, y: rect.minY + 44, width: rect.width - 36, height: rect.height - 44 - 52)
        let k = min(room.width / width, room.height / height, 1)
        ctx.withState {
            ctx.translateBy(x: rect.midX - width * k / 2, y: room.minY + max(0, (room.height - height * k) / 2))
            ctx.scaleBy(x: k, y: k)
            PaceCardRenderer.draw(model, origin: .zero, width: width, theme: t, ctx: ctx)
        }
        Text("LIVE PREVIEW", F.sf(9.5, 700), t.muted, kern: 1).draw(x: rect.midX, capCenter: rect.maxY - 30, align: .center, in: ctx)
    }

    /// The alerts that are on, as macOS would stack them.
    private static func notifications(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        let samples: [(NotificationKind, String, String)] = [
            (.sessionWarning, "Claude: 5-hour session 84% used", "16% left · resets 10:48 AM. At this rate it runs out around 10:41 AM."),
            (.sessionLimit, "Claude: 5-hour limit reached", "Back at 10:48 AM, in 48m."),
            (.sessionReset, "Claude: 5-hour session is back", "A fresh session is ready. The full allowance is available again."),
            (.weeklyTight, "Codex: getting tight this week", "Runs out Thursday 11:31 PM at today's pace."),
            (.creditsExpiring, "Codex: a reset credit lapses soon", "It expires Thu 6:00 AM. Headroom never redeems one for you."),
        ]
        let on = samples.filter { settings.notifies($0.0) }
        let x = rect.minX + 16, w = rect.width - 32
        guard !on.isEmpty else {
            let c = CGPoint(x: rect.midX, y: rect.midY - 20)
            CanvasControlView.drawSymbol("bell.slash", in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44), color: t.muted, weight: .regular, ctx: ctx)
            Text("All quiet", F.sf(15, 650), t.ink).draw(x: rect.midX, capCenter: c.y + 44, align: .center, in: ctx)
            Text("Headroom won't send any alerts.", F.sf(12, 500), t.muted).draw(x: rect.midX, capCenter: c.y + 66, align: .center, in: ctx)
            return
        }
        var y = rect.minY + 48
        for (_, title, body) in on {
            y += OnboardingStage.notification(title: title, body: body, x: x, y: y, w: w, theme: t, ctx: ctx) + 10
        }
        Text("\(on.count) OF \(samples.count) ON", F.sf(9.5, 700), t.muted, kern: 1).draw(x: rect.midX, capCenter: rect.maxY - 30, align: .center, in: ctx)
    }

    /// `headroom` in a Terminal window: what the command line tool prints.
    private static func terminal(_ rect: CGRect, theme t: Theme, ctx: CGContext) {
        let win = CGRect(x: rect.minX + 16, y: rect.minY + 64, width: rect.width - 32, height: 236)
        let shape = rounded(win, 12)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: black(t.isDark ? 0.5 : 0.22).cgColor)
            ctx.fill(shape, rgb(0x16171C, 0.97))
        }
        ctx.innerStroke(shape, white(0.10), width: 0.5)
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: win.minX + 12 + CGFloat(i) * 16, y: win.minY + 11, width: 10, height: 10))
            ctx.fill(dot, rgb(UInt32(hex)))
        }
        Text("zsh", F.sf(11, 600), white(0.45)).draw(x: win.midX, capCenter: win.minY + 16, align: .center, in: ctx)
        ctx.fill(CGPath(rect: CGRect(x: win.minX, y: win.minY + 31, width: win.width, height: 0.5), transform: nil), white(0.08))

        let mono = F.mono(10.5, 500), bold = F.mono(10.5, 700)
        let ink = white(0.88), dim = white(0.45)
        let plenty = Theme.dark.pacing(.plenty), tight = Theme.dark.pacing(.tight)
        var y = win.minY + 50
        let x0 = win.minX + 14
        func line(_ parts: [(String, NSFont, NSColor)], cells: (Int, PacingColors)? = nil, at x: CGFloat = x0) {
            var cx = x
            for (i, part) in parts.enumerated() {
                let text = Text(part.0, part.1, part.2)
                text.draw(x: cx, capCenter: y, in: ctx)
                cx += text.width
                if i == 0, let (n, colors) = cells {
                    for c in 0..<5 {
                        let r = rounded(CGRect(x: cx + CGFloat(c) * 9, y: y - 4.5, width: 7.5, height: 9), 2)
                        ctx.fill(r, c < n ? colors.bottom : white(0.12))
                    }
                    cx += 5 * 9 + 6
                }
            }
            y += 18
        }
        line([("$ ", mono, dim), ("headroom", bold, ink)])
        y += 4
        line([("Claude ", bold, ink), ("82% · renews in 20h", mono, ink)], cells: (4, plenty))
        line([("  ↳ ", mono, dim), ("plenty", mono, plenty.text), (" · spend it before it renews", mono, dim)])
        line([("  ↳ ", mono, dim), ("⚠ 5-hour session 16% left", mono, tight.text)])
        line([("Codex  ", bold, ink), ("59% · renews in 4d", mono, ink)], cells: (3, tight))
        line([("  ↳ ", mono, dim), ("tight", mono, tight.text), (" · runs out Thu 11:31 PM", mono, dim)])
        y += 8
        line([("$ ", mono, dim), ("headroom wait", bold, ink)])
        line([("Waiting for Claude · back 10:48 AM", mono, dim)])
        line([("$ ", mono, dim), ("▍", mono, ink)])

        Text("THE HEADROOM COMMAND", F.sf(9.5, 700), t.muted, kern: 1).draw(x: rect.midX, capCenter: win.maxY + 34, align: .center, in: ctx)
        Text("Your week in Terminal, prompts and tmux.", F.sf(12, 500), t.muted).draw(x: rect.midX, capCenter: win.maxY + 54, align: .center, in: ctx)
    }
}
