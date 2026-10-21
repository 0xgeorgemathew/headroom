import AppKit
import HeadroomKit

/// `HeadroomApp --render <scenario|all> --out <dir> [--light|--dark]`: draws surfaces offscreen
/// to PNG at 2×, for the visual pass against the mockups. Never touches live data.
@MainActor
enum RenderCommand {
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        // Pinned so the images look the same on every machine (README screenshots).
        Display.locale = Locale(identifier: "en_US")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Display.locale
        Display.calendar = cal
        let name = value("--render") ?? "all"
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let themes: [Theme] = args.contains("--light") ? [.light] : args.contains("--dark") ? [.dark] : [.dark, .light]
        let now = Demo.now
        var written = 0
        for theme in themes {
            for s in Demo.paceScenarios(now: now) where name == "all" || name == s.name || name == "pace" {
                if let rep = PopoverPage.renderPace(s.inputs, theme: theme, now: now) {
                    write(rep, to: outDir.appendingPathComponent("pace-\(s.name)-\(theme.isDark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "activity" {
            for theme in themes {
                for mode in [ActivityMode.all, .newOnly] {
                    for range in ActivityRange.allCases where mode == .all || range == .day {
                        if let rep = PopoverPage.renderActivity(theme: theme, mode: mode, range: range, collecting: false) {
                            write(rep, to: outDir.appendingPathComponent("activity-\(mode == .all ? "all" : "new")-\(range.label.lowercased())-\(theme.isDark ? "dark" : "light").png")); written += 1
                        }
                    }
                }
                if let rep = PopoverPage.renderActivity(theme: theme, mode: .all, range: .day, collecting: true) {
                    write(rep, to: outDir.appendingPathComponent("activity-collecting-\(theme.isDark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "statusitem" {
            // The status item alone on a transparent background (3×), for marketing images.
            let presenter = Presenter(now: now)
            let items = presenter.menuBarItems([Demo.claudeMockup(now: now), Demo.codexMockup(now: now)], mode: .both, enabled: [.claude, .codex])
            let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
            for dark in [true, false] {
                if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: 3) {
                    write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-\(dark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "menubar-options" {
            for dark in [true, false] {
                for (option, options, mode) in PopoverPage.menuBarOptionRows {
                    let items = Demo.menuBarItems(options: options, mode: mode)
                    let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
                    if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: 3) {
                        write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-\(option)-\(dark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "sessions" {
            for theme in themes {
                if let rep = PopoverPage.renderSessionHistory(theme: theme) {
                    write(rep, to: outDir.appendingPathComponent("sessions-\(theme.isDark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "menubar" {
            if let rep = PopoverPage.renderMenuBars(now: now) { write(rep, to: outDir.appendingPathComponent("menubar.png")); written += 1 }
        }
        if name == "all" || name == "share" {
            let shares = PopoverPage.demoShares()
            if let rep = ShareCardRenderer.card(shares[0]) { write(rep, to: outDir.appendingPathComponent("share-card-claude.png")); written += 1 }
            if let rep = ShareCardRenderer.card(shares[1]) { write(rep, to: outDir.appendingPathComponent("share-card-codex.png")); written += 1 }
            if let rep = ShareCardRenderer.snapshot(shares) { write(rep, to: outDir.appendingPathComponent("share-snapshot.png")); written += 1 }
            try? ShareBuilder.text(shares).write(to: outDir.appendingPathComponent("share-text.txt"), atomically: true, encoding: .utf8)
        }
        if name == "all" || name == "session" {
            for theme in themes {
                for (state, used) in PopoverPage.sessionStates {
                    if let rep = PopoverPage.renderSessionCard(used: used, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("session-\(state)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "onboarding" {
            for theme in themes {
                for step in 0..<OnboardingView.steps.count {
                    if let rep = PopoverPage.renderOnboarding(step: step, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("onboarding-\(step + 1)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "settings" {
            for theme in themes {
                for section in SettingsView.Section.allCases {
                    if let rep = PopoverPage.renderSettings(section: section, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("settings-\(section.rawValue + 1)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        print("rendered \(written) image(s) to \(outDir.path)")
        return 0
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}

/// Composes whole popover pages offscreen (same drawing code as the live popover).
@MainActor
enum PopoverPage {
    static func renderPace(_ inputs: [PaceInput], theme: Theme, now: Date) -> NSBitmapImageRep? {
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let cards = inputs.map { presenter.paceCard($0) }
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        var h = pad + PopoverChrome.headerHeight
        for (i, c) in cards.enumerated() { h += (i > 0 ? 10 : 0) + PaceCardRenderer.draw(c, origin: .zero, width: cw, theme: theme, ctx: nil) }
        h += PopoverChrome.footerHeight + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: h), theme: theme, ctx: ctx)
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, selected: 0, theme: theme, ctx: ctx, out: nil)
            var y = pad + PopoverChrome.headerHeight
            for (i, c) in cards.enumerated() {
                if i > 0 { y += 10 }
                y += PaceCardRenderer.draw(c, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            PopoverChrome.drawFooter(FooterModel(text: "All systems normal", status: .fresh), x: pad, y: y, width: cw, theme: theme, ctx: ctx, out: nil)
        }
    }

    static func renderActivity(theme: Theme, mode: ActivityMode, range: ActivityRange, collecting: Bool) -> NSBitmapImageRep? {
        let now = Demo.activityNow
        let pricing = (try? PriceTable.bundled()).map { PricingEngine(table: $0) }
        let presenter = ActivityPresenter(now: now, locale: Locale(identifier: "en_US"), pricing: pricing)
        let aggregates = pricing.map { Demo.activityAggregates(now: now, pricing: $0) } ?? []
        let selection: Range<Int>? = range == .day ? 4..<8 : nil
        let cards = [Provider.claude, .codex].map { presenter.card($0, aggregates: aggregates, range: range, selection: selection) }
        let weeks = Demo.pastWeeks(collecting: collecting)
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        func layout(_ ctx: CGContext?) -> CGFloat {
            var y = pad + PopoverChrome.headerHeight
            if let ctx {
                let modes = Segmented(items: ["All", "New only"], selected: mode.rawValue, font: F.sf(11.5, 600), padX: 10, height: 26)
                modes.draw(in: CGRect(x: pad + 1, y: y, width: modes.width, height: 26), theme: theme, ctx: ctx, out: nil) { .activityMode($0) }
                let ranges = Segmented(items: ActivityRange.allCases.map(\.label), selected: range.rawValue, font: F.sf(11.5, 600), padX: 10, height: 26)
                ranges.draw(in: CGRect(x: pad + cw - 1 - ranges.width, y: y, width: ranges.width, height: 26), theme: theme, ctx: ctx, out: nil) { .activityRange($0) }
            }
            y += 26 + 10
            for (i, c) in cards.enumerated() {
                if i > 0 { y += 10 }
                y += ActivityCardRenderer.draw(c, mode: mode, breakdown: .model, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            y += 16
            if let ctx { PastWeeksRenderer.drawSectionHeader(x: pad, y: y, width: cw, theme: theme, ctx: ctx) }
            y += PastWeeksRenderer.sectionHeaderHeight
            for (i, wk) in weeks.enumerated() {
                if i > 0 { y += 10 }
                y += PastWeeksRenderer.draw(wk, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            if !collecting {
                if let ctx { PastWeeksRenderer.drawLegend(x: pad, y: y, width: cw, theme: theme, ctx: ctx) }
                y += PastWeeksRenderer.legendHeight
            }
            y += 6
            if let ctx { SessionHistoryRenderer.drawSectionHeader(x: pad, y: y, width: cw, warnAt: 0.75, theme: theme, ctx: ctx) }
            y += SessionHistoryRenderer.sectionHeaderHeight
            for (i, p) in [Provider.claude, .codex].enumerated() {
                if i > 0 { y += 10 }
                let m = SessionHistoryRenderer.model(p, sessions: collecting ? [] : Demo.sessionHistory(p, now: Demo.now), warnAt: 0.75, now: Demo.now)
                y += SessionHistoryRenderer.draw(m, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            y += 4
            if let ctx { PopoverChrome.drawFooter(FooterModel(text: "All systems normal", status: .fresh), x: pad, y: y, width: cw, theme: theme, ctx: ctx, out: nil) }
            return y + PopoverChrome.footerHeight + pad
        }
        let measured = measureHeight(layout)
        return renderImage(size: CGSize(width: w, height: measured)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: measured), theme: theme, ctx: ctx)
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, selected: 1, theme: theme, ctx: ctx, out: nil)
            _ = layout(ctx)
        }
    }

    /// Runs a layout pass against a scratch context to learn its height.
    static func measureHeight(_ layout: @escaping (CGContext?) -> CGFloat) -> CGFloat {
        var height: CGFloat = 0
        _ = renderImage(size: CGSize(width: 4, height: 4), scale: 1) { ctx in height = layout(ctx) }
        return height
    }

    /// Menu bar strips on dark, light and busy wallpapers, for every override.
    static func renderMenuBars(now: Date) -> NSBitmapImageRep? {
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let rows: [(String, [PaceInput])] = [
            ("mockup", [Demo.claudeMockup(now: now), Demo.codexMockup(now: now)]),
            ("on pace + very tight", [Demo.state(.claude, used: 0.52, elapsedH: 84, now: now), Demo.state(.codex, used: 0.82, elapsedH: 72, now: now)]),
            ("rose session + blocked", [Demo.state(.claude, used: 0.46, elapsedH: 90, session: 0.94, now: now), Demo.state(.codex, used: 0.46, elapsedH: 90, session: 1, now: now)]),
            ("fault + weekly blocked", [Demo.state(.claude, used: 0.46, elapsedH: 90, fault: .offline, now: now), Demo.state(.codex, used: 1, elapsedH: 140, now: now)]),
        ]
        let w: CGFloat = 340, stripH: CGFloat = 28
        let backgrounds = ["dark", "light", "busy"]
        let h = CGFloat(rows.count * backgrounds.count) * (stripH + 6) + 6
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), rgb(0x808080))
            var y: CGFloat = 6
            for bg in backgrounds {
                for (_, inputs) in rows {
                    let r = CGRect(x: 6, y: y, width: w - 12, height: stripH)
                    let dark = bg != "light"
                    switch bg {
                    case "dark": ctx.fillLinear(rounded(r, 6), [rgb(0x1A2150), rgb(0x3B2A5C), rgb(0x0F2F45)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    case "light": ctx.fillLinear(rounded(r, 6), [rgb(0xD6E4F7), rgb(0xF4E2EC), rgb(0xD8EEE7)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    default:
                        ctx.fillLinear(rounded(r, 6), [rgb(0xE07A2F), rgb(0x2C7A4B), rgb(0xC9D84A), rgb(0x3A3FB0)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    }
                    ctx.fill(rounded(r, 6), dark ? rgb(0x080810, 0.3) : white(0.45))
                    let items = presenter.menuBarItems(inputs, mode: .both, enabled: [.claude, .codex])
                    let iw = StatusItemRenderer.width(items)
                    StatusItemRenderer.draw(items, in: CGRect(x: r.maxX - 12 - iw, y: r.midY - 11, width: iw, height: 22), dark: dark, ctx: ctx)
                    y += stripH + 6
                }
            }
        }
    }

    /// One welcome step at window size, with the window's traffic lights, from scratch settings.
    static func renderOnboarding(step: Int, theme: Theme, configure: ((AppSettings) -> Void)? = nil) -> NSBitmapImageRep? {
        let suite = "com.headroom.render.onboarding"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // The welcome as a typical user sees it: both tools found, a timer always on, the warning at 75%.
        settings.alwaysShowSessionTimer = step >= 2
        configure?(settings)
        let view = OnboardingView(settings: settings) { p in .signedIn(plan: p == .claude ? "MAX 20×" : "PRO") }
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let size = OnboardingView.size
        return renderImage(size: size, appearance: view.appearance) { ctx in
            let shape = rounded(CGRect(origin: .zero, size: size), 12)
            ctx.addPath(shape); ctx.clip()
            view.render(step: step, ctx: ctx)
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: 20 + CGFloat(i) * 20, y: 18, width: 12, height: 12))
                ctx.fill(dot, rgb(UInt32(hex)))
                ctx.stroke(dot, black(0.12), width: 0.5)
            }
            ctx.innerStroke(shape, theme.isDark ? white(0.12) : black(0.1), width: 1)
        }
    }

    /// One Settings section at window size, from scratch settings.
    static func renderSettings(section: SettingsView.Section, theme: Theme, configure: ((AppSettings) -> Void)? = nil) -> NSBitmapImageRep? {
        let suite = "com.headroom.render.settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.alwaysShowSessionTimer = true
        configure?(settings)
        let view = SettingsView(settings: settings, model: nil)
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let size = SettingsView.size
        return renderImage(size: size, appearance: view.appearance) { ctx in
            let shape = rounded(CGRect(origin: .zero, size: size), 12)
            ctx.addPath(shape); ctx.clip()
            view.render(section: section, ctx: ctx)
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: 20 + CGFloat(i) * 20, y: 18, width: 12, height: 12))
                ctx.fill(dot, rgb(UInt32(hex)))
                ctx.stroke(dot, black(0.12), width: 0.5)
            }
            ctx.innerStroke(shape, theme.isDark ? white(0.12) : black(0.1), width: 1)
        }
    }

    static let sessionStates: [(String, Double)] = [("idle", 0), ("comfortable", 0.42), ("runsout", 0.6), ("amber", 0.84), ("rose", 0.94), ("blocked", 1)]

    /// A card cut down to its header and the detailed 5-hour panel.
    static func renderSessionCard(used: Double, theme: Theme) -> NSBitmapImageRep? {
        let now = Demo.now
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let input = Demo.state(.claude, used: 0.46, elapsedH: 90, session: used, now: now)
        var card = presenter.paceCard(input)
        guard var module = card.sessionModule else { return nil }
        module.onTop = true
        card.sessionModule = module
        let m: CGFloat = 12, w: CGFloat = 360, pad: CGFloat = 14
        let mh = PaceCardRenderer.sessionModuleHeight(module, width: w - pad * 2)
        let h = 13 + 28 + 12 + mh + 14
        return renderImage(size: CGSize(width: w + m * 2, height: h + m * 2)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w + m * 2, height: h + m * 2), transform: nil), theme.windowFill)
            CardChrome.draw(CGRect(x: m, y: m, width: w, height: h), provider: .claude, theme: theme, ctx: ctx)
            PaceCardRenderer.drawHeader(card, x: m + pad, y: m + 13, w: w - pad * 2, theme: theme, ctx: ctx, out: nil)
            PaceCardRenderer.drawSessionModule(module, rect: CGRect(x: m + pad, y: m + 13 + 28 + 12, width: w - pad * 2, height: mh), theme: theme, ctx: ctx)
        }
    }

    /// The menu bar under each Settings choice, one strip per row, at 3×.
    static let menuBarOptionRows: [(String, PresentationOptions, MenuBarMode)] = [
        ("default", PresentationOptions(), .both),
        ("percent", PresentationOptions(showPercent: true), .both),
        ("session", PresentationOptions(meterFocus: .session, alwaysShowSessionTimer: true), .both),
        ("tighter", PresentationOptions(meterFocus: .tighter, showPercent: true), .both),
        ("urgent", PresentationOptions(alwaysShowSessionTimer: true), .mostUrgent),
    ]

    /// The Activity tab's 5-hour sessions section on its own.
    static func renderSessionHistory(theme: Theme) -> NSBitmapImageRep? {
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        let models = [Provider.claude, .codex].map { SessionHistoryRenderer.model($0, sessions: Demo.sessionHistory($0, now: Demo.now), warnAt: 0.75, now: Demo.now) }
        let h = pad + SessionHistoryRenderer.sectionHeaderHeight + models.reduce(0) { $0 + SessionHistoryRenderer.draw($1, origin: .zero, width: cw, theme: theme, ctx: nil) } + 10 + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), theme.windowFill)
            var y = pad
            SessionHistoryRenderer.drawSectionHeader(x: pad, y: y, width: cw, warnAt: 0.75, theme: theme, ctx: ctx)
            y += SessionHistoryRenderer.sectionHeaderHeight
            for (i, m) in models.enumerated() {
                if i > 0 { y += 10 }
                y += SessionHistoryRenderer.draw(m, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
        }
    }

    static func demoShares() -> [ShareModel] {
        let now = Demo.activityNow
        let pricing = (try? PriceTable.bundled()).map { PricingEngine(table: $0) }
        let ap = ActivityPresenter(now: now, locale: Locale(identifier: "en_US"), pricing: pricing)
        let aggregates = pricing.map { Demo.activityAggregates(now: now, pricing: $0) } ?? []
        let pp = Presenter(now: Demo.now, locale: Locale(identifier: "en_US"))
        let paces = [pp.paceCard(Demo.claudeMockup(now: Demo.now)), pp.paceCard(Demo.codexMockup(now: Demo.now))]
        return [Provider.claude, .codex].enumerated().map { i, p in
            let card = ap.card(p, aggregates: aggregates, range: .day, selection: 4..<8)
            return ShareBuilder.make(activity: card, pace: paces[i], mode: .all, includeCost: true, burnInSpan: i == 0 ? 0.01 : 0.06, durationText: "4 hours")
        }
    }
}
