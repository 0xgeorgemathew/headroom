import AppKit
import HeadroomKit

/// `HeadroomApp --render <scenario|all> --out <dir> [--light|--dark]`: draws surfaces offscreen
/// to PNG at 2×, for the visual pass against the mockups. Never touches live data.
@MainActor
enum RenderCommand {
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
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
}
