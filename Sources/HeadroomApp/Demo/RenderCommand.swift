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
}
