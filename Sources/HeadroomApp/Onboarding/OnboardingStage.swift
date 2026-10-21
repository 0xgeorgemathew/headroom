import AppKit
import HeadroomKit

/// The left half of the welcome window: a wallpaper-like stage that shows what each step does,
/// drawn with the same renderers as the live app so the previews are exact.
@MainActor
enum OnboardingStage {
    static func draw(step: Int, rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        let shape = rounded(rect, 18)
        drawWallpaper(shape, rect: rect, theme: t, ctx: ctx)
        ctx.withState {
            ctx.addPath(shape); ctx.clip()
            switch step {
            case 0: welcome(rect, theme: t, ctx: ctx)
            case 1: providers(rect, settings: settings, theme: t, ctx: ctx)
            case 2: menuBar(rect, settings: settings, theme: t, ctx: ctx)
            case 3: session(rect, settings: settings, theme: t, ctx: ctx)
            default: ready(rect, settings: settings, theme: t, ctx: ctx)
            }
        }
        ctx.innerStroke(shape, t.isDark ? white(0.08) : black(0.06), width: 1)
    }

    static func drawWallpaper(_ shape: CGPath, rect: CGRect, theme t: Theme, ctx: CGContext) {
        if t.isDark {
            ctx.fillLinear(shape, [rgb(0x161A36), rgb(0x0C0E18), rgb(0x0A1A24)], from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), locations: [0, 0.6, 1])
        } else {
            ctx.fillLinear(shape, [rgb(0xE6ECF8), rgb(0xF3EEF2), rgb(0xE4F1EC)], from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), locations: [0, 0.6, 1])
        }
        let a: CGFloat = t.isDark ? 1 : 0.9
        ctx.fillRadial(in: shape, center: CGPoint(x: rect.maxX - 30, y: rect.minY + 60), radii: CGSize(width: 260, height: 240),
                       color: rgb(0x4A8EFF, 0.42 * a), fadeAt: 0.9)
        ctx.fillRadial(in: shape, center: CGPoint(x: rect.minX, y: rect.maxY - 20), radii: CGSize(width: 240, height: 220),
                       color: rgb(0xD97757, (t.isDark ? 0.34 : 0.38) * a), fadeAt: 0.9)
        ctx.fillRadial(in: shape, center: CGPoint(x: rect.midX + 60, y: rect.maxY + 40), radii: CGSize(width: 220, height: 200),
                       color: rgb(0x10A37F, (t.isDark ? 0.30 : 0.30) * a), fadeAt: 0.9)
    }

    // MARK: Steps

    private static func welcome(_ rect: CGRect, theme t: Theme, ctx: CGContext) {
        let side: CGFloat = 128
        let c = CGPoint(x: rect.midX, y: rect.midY - 40)
        ctx.fillRadial(in: CGPath(rect: rect, transform: nil), center: c, radii: CGSize(width: 150, height: 150), color: rgb(0x4A8EFF, t.isDark ? 0.35 : 0.25), fadeAt: 1)
        HeadroomMark.draw(in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side), ctx: ctx)
        Text("Headroom", F.sf(22, 700), t.ink, kern: -0.4).draw(x: rect.midX, capCenter: c.y + side / 2 + 30, align: .center, in: ctx)
        menuBarStrip(Demo.menuBarItems(options: PresentationOptions()), rect: CGRect(x: rect.minX + 18, y: rect.maxY - 64, width: rect.width - 36, height: 30), theme: t, ctx: ctx)
    }

    static func providers(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        let side: CGFloat = 84, gap: CGFloat = 34
        let y = rect.midY - side / 2 - 16
        for (i, p) in Provider.allCases.enumerated() {
            let on = settings.enabledProviders.contains(p)
            let x = rect.midX - side - gap / 2 + CGFloat(i) * (side + gap)
            let tile = CGRect(x: x, y: y, width: side, height: side)
            let brand = Brand.of(p)
            if on {
                ctx.fillRadial(in: CGPath(rect: rect, transform: nil), center: CGPoint(x: tile.midX, y: tile.midY), radii: CGSize(width: 90, height: 90),
                               color: brand.base.fade(t.isDark ? 0.5 : 0.35), fadeAt: 1)
            }
            ctx.withState {
                ctx.setAlpha(on ? 1 : 0.28)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                BrandMark.drawTile(p, in: tile, ctx: ctx)
                ctx.endTransparencyLayer()
            }
            Text(p == .claude ? "Claude Code" : "Codex", F.sf(13, 650), t.ink.fade(on ? 1 : 0.4)).draw(x: tile.midX, capCenter: tile.maxY + 22, align: .center, in: ctx)
        }
        let n = settings.enabledProviders.count
        let caption = n == 2 ? "Both, side by side" : n == 1 ? "Just one" : "None yet"
        Text(caption.uppercased(), F.sf(9.5, 700), t.muted, kern: 1).draw(x: rect.midX, capCenter: rect.maxY - 46, align: .center, in: ctx)
    }

    static func menuBar(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        let items = Demo.menuBarItems(options: settings.presentation, mode: settings.menuBarMode, enabled: settings.enabledProviders, policy: settings.policy)
        menuBarStrip(items, rect: CGRect(x: rect.minX + 14, y: rect.minY + 48, width: rect.width - 28, height: 30), theme: t, ctx: ctx)
        // Each provider's group, magnified, centered in the space under the strip.
        let zooms = items.map { min(2.8, (rect.width - 72) / max(StatusItemRenderer.width([$0]), 1)) }
        let stack = zooms.reduce(0) { $0 + 22 * $1 + 34 } + CGFloat(max(items.count - 1, 0)) * 12 + 70
        var y = max(rect.minY + 112, rect.minY + 78 + (rect.height - 78 - stack) / 2)
        var boxBottom = y
        for item in items {
            let w = StatusItemRenderer.width([item])
            let zoom = min(2.8, (rect.width - 72) / max(w, 1))
            let box = CGRect(x: rect.minX + 20, y: y, width: rect.width - 40, height: 22 * zoom + 34)
            let shape = rounded(box, 18)
            ctx.fill(shape, t.isDark ? rgb(0x0A0B10, 0.5) : white(0.6))
            ctx.innerStroke(shape, t.isDark ? white(0.08) : black(0.05), width: 1)
            ctx.withState {
                ctx.translateBy(x: box.midX - w * zoom / 2, y: box.midY - 11 * zoom)
                ctx.scaleBy(x: zoom, y: zoom)
                StatusItemRenderer.draw([item], in: CGRect(x: 0, y: 0, width: w, height: 22), dark: t.isDark, ctx: ctx)
            }
            y = box.maxY + 12
            boxBottom = box.maxY
        }
        let box = CGRect(x: rect.minX, y: boxBottom - 1, width: rect.width, height: 1)
        Text("LIVE PREVIEW", F.sf(9.5, 700), t.muted, kern: 1).draw(x: rect.midX, capCenter: box.maxY + 22, align: .center, in: ctx)
        let what: String = switch settings.meterFocus {
        case .week: "Cells show what's left this week"
        case .session: "Cells show the 5-hour session (5H)"
        case .tighter: "Cells switch to the session when it's tighter"
        }
        Text(what, F.sf(12, 500), t.muted).draw(x: rect.midX, capCenter: box.maxY + 42, align: .center, in: ctx)
    }

    static func session(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        var options = settings.presentation
        options.sessionDetail = .detailed
        var presenter = Presenter(now: Demo.now, policy: settings.policy, options: options)
        presenter.locale = Display.locale
        let input = Demo.claudeMockup(now: Demo.now)
        guard let reading = input.reading, let status = SessionStatus(window: reading.session, now: Demo.now, policy: settings.policy) else { return }
        let samples = input.samples[LimitWindow.sessionID()] ?? []
        let f = SessionForecast(window: reading.session, samples: samples, now: Demo.now)
        var module = presenter.sessionModule(status, forecast: f, weekLeft: reading.headline?.remaining, samples: samples)
        module.onTop = true
        let x = rect.minX + 16, w = rect.width - 32
        var y = rect.minY + 46
        // A notification, as macOS would show it.
        if settings.notifies(.sessionWarning), status.level >= .amber, let resets = status.resetsAt {
            let body = "\(presenter.percent(status.remaining)) left · resets \(TimeFormat.clock(resets, calendar: Display.calendar, locale: Display.locale))."
                + (f.runsOutAt.map { " At this rate it runs out around \(TimeFormat.shortClock($0, calendar: Display.calendar, locale: Display.locale))." } ?? "")
            y += notification(title: "Claude: 5-hour session \(presenter.percent(status.used)) used", body: body, x: x, y: y, w: w, theme: t, ctx: ctx) + 14
        } else {
            y += 26
        }
        let cardPad: CGFloat = 12
        let mh = PaceCardRenderer.sessionModuleHeight(module, width: w - cardPad * 2)
        let card = CGRect(x: x, y: y, width: w, height: 28 + 12 + mh + cardPad)
        CardChrome.draw(card, provider: .claude, theme: t, ctx: ctx)
        BrandMark.drawTile(.claude, in: CGRect(x: card.minX + cardPad, y: card.minY + 12, width: 22, height: 22), ctx: ctx)
        Text("Claude", F.sf(13.5, 650), t.ink).draw(x: card.minX + cardPad + 30, capCenter: card.minY + 23, in: ctx)
        PaceCardRenderer.drawSessionModule(module, rect: CGRect(x: card.minX + cardPad, y: card.minY + 28 + 12, width: w - cardPad * 2, height: mh), theme: t, ctx: ctx)
        let note = status.level >= .amber ? "Warns from \(Int((settings.sessionWarnAt * 100).rounded()))% · this one is at 84%"
            : "Warns from \(Int((settings.sessionWarnAt * 100).rounded()))% · this one is at 84%, so it stays calm"
        Text(note, F.sf(11.5, 500), t.muted).draw(x: rect.midX, capCenter: card.maxY + 20, align: .center, in: ctx)
    }

    private static func ready(_ rect: CGRect, settings: AppSettings, theme t: Theme, ctx: CGContext) {
        let side: CGFloat = 112
        let c = CGPoint(x: rect.midX, y: rect.midY - 56)
        ctx.fillRadial(in: CGPath(rect: rect, transform: nil), center: c, radii: CGSize(width: 150, height: 150), color: rgb(0x30D158, t.isDark ? 0.22 : 0.18), fadeAt: 1)
        HeadroomMark.draw(in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side), ctx: ctx)
        // A few sparks around the mark.
        let sparks: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(-86, -40, 12, 0x8CC2FF), (82, -58, 9, 0xFFC248), (92, 30, 13, 0xECEDF1), (-74, 48, 8, 0xFF6982), (-20, -88, 7, 0x8CC2FF)]
        for (dx, dy, s, hex) in sparks {
            ctx.withState {
                ctx.setShadow(offset: .zero, blur: 8, color: rgb(hex, 0.8).cgColor)
                Glyph.spark(in: CGRect(x: c.x + dx - s / 2, y: c.y + dy - s / 2, width: s, height: s), color: rgb(hex), ctx: ctx)
            }
        }
        // The menu bar as it's now set up.
        let items = Demo.menuBarItems(options: settings.presentation, mode: settings.menuBarMode, enabled: settings.enabledProviders, policy: settings.policy)
        menuBarStrip(items, rect: CGRect(x: rect.minX + 18, y: c.y + side / 2 + 40, width: rect.width - 36, height: 30), theme: t, ctx: ctx)
        let summary = [
            settings.enabledProviders.sorted().map(\.displayName).joined(separator: " + "),
            "warns at \(Int((settings.sessionWarnAt * 100).rounded()))%",
            settings.meterFocus == .week ? "weekly meter" : settings.meterFocus == .session ? "session meter" : "tighter meter",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        Text(summary, F.sf(11.5, 500), t.muted).draw(x: rect.midX, capCenter: c.y + side / 2 + 98, align: .center, in: ctx)
    }

    // MARK: Pieces

    /// A slice of menu bar with the status item at its right, like the README hero.
    static func menuBarStrip(_ items: [MenuBarProviderModel], rect: CGRect, theme t: Theme, ctx: CGContext) {
        let shape = rounded(rect, 9)
        ctx.fill(shape, t.isDark ? rgb(0x080910, 0.5) : white(0.55))
        ctx.innerStroke(shape, t.isDark ? white(0.07) : black(0.05), width: 0.5)
        let clock = Text("Tue 10:02", F.sf(12, 500, tabular: true), t.ink.fade(0.9))
        clock.draw(x: rect.maxX - 10, capCenter: rect.midY, align: .right, in: ctx)
        let w = StatusItemRenderer.width(items)
        let x = rect.maxX - 10 - clock.width - 12 - w
        ctx.withState {
            if x < rect.minX + 6 {
                // Too wide for the strip: scale it down rather than clip it.
                let k = (rect.maxX - 10 - clock.width - 12 - rect.minX - 6) / w
                ctx.translateBy(x: rect.minX + 6, y: rect.midY - 11 * k)
                ctx.scaleBy(x: k, y: k)
                StatusItemRenderer.draw(items, in: CGRect(x: 0, y: 0, width: w, height: 22), dark: t.isDark, ctx: ctx)
            } else {
                StatusItemRenderer.draw(items, in: CGRect(x: x, y: rect.midY - 11, width: w, height: 22), dark: t.isDark, ctx: ctx)
            }
        }
    }

    /// A macOS-style notification banner. Returns its height.
    static func notification(title: String, body: String, x: CGFloat, y: CGFloat, w: CGFloat, theme t: Theme, ctx: CGContext) -> CGFloat {
        let bodyBlock = TextBlock(body, F.sf(11.5), t.ink.fade(0.82), width: w - 56, lineHeight: 15)
        let h = 12 + 15 + bodyBlock.height + 12
        let r = CGRect(x: x, y: y, width: w, height: h)
        let shape = rounded(r, 16)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: black(t.isDark ? 0.45 : 0.15).cgColor)
            ctx.fill(shape, t.isDark ? rgb(0x2A2B31, 0.96) : white(0.96))
        }
        ctx.innerStroke(shape, t.isDark ? white(0.10) : black(0.05), width: 0.5)
        HeadroomMark.draw(in: CGRect(x: r.minX + 11, y: r.minY + 12, width: 28, height: 28), ctx: ctx, dropShadow: false)
        Text(title, F.sf(12, 650), t.ink).draw(x: r.minX + 47, baseline: baseline(top: r.minY + 11, font: F.sf(12, 650), lineHeight: 15), in: ctx)
        bodyBlock.draw(x: r.minX + 47, top: r.minY + 11 + 16, in: ctx)
        return h
    }
}

extension Demo {
    /// The mockup's two providers in the menu bar, with the given Settings applied.
    static func menuBarItems(options: PresentationOptions, mode: MenuBarMode = .both, enabled: Set<Provider> = [.claude, .codex],
                             policy: PacingPolicy = .standard) -> [MenuBarProviderModel] {
        var presenter = Presenter(now: now, policy: policy, options: options)
        presenter.locale = Display.locale
        return presenter.menuBarItems([claudeMockup(now: now), codexMockup(now: now)], mode: mode, enabled: enabled)
    }
}
