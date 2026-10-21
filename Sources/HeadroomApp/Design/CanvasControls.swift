import AppKit
import HeadroomKit

/// A CPU-drawn window surface with clickable regions: the welcome window and Settings share it,
/// so their segmented controls, switches and buttons look and behave the same.
@MainActor
class CanvasControlView: NSView {
    /// Clickable areas from the last draw; the last match wins.
    var regions: [(rect: CGRect, action: AnyHashable)] = []
    var hovered: AnyHashable?
    private var fade: (image: CGImage, start: Date)?
    private var fadeTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var theme: Theme { Theme.current(for: effectiveAppearance) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Subclass hooks

    func drawContent(_ ctx: CGContext) {}
    func handle(_ action: AnyHashable) {}

    // MARK: Drawing

    /// Snapshots the current content and fades it out over the next draw (page changes).
    func crossfade() {
        guard window != nil, let image = CPUCanvas.image(for: self, { self.drawContent($0) }) else { return }
        fade = (image, Date())
        fadeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let f = self.fade else { return }
                if Date().timeIntervalSince(f.start) >= 0.22 { self.fade = nil; self.fadeTimer?.invalidate(); self.fadeTimer = nil }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    override func updateLayer() {
        let alpha = fade.map { 1 - min(1, Date().timeIntervalSince($0.start) / 0.22) }
        CPUCanvas.update(self) { ctx in
            self.regions.removeAll()
            self.drawContent(ctx)
            if let f = self.fade, let a = alpha {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(a * a))
                ctx.translateBy(x: 0, y: self.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(f.image, in: CGRect(origin: .zero, size: self.bounds.size))
                ctx.restoreGState()
            }
        }
    }

    // MARK: Input

    func hit(_ rect: CGRect, _ action: some Hashable) { regions.append((rect, AnyHashable(action))) }
    func isHovered(_ action: some Hashable) -> Bool { hovered == AnyHashable(action) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = regions.last { $0.rect.contains(p) }?.action
        if h != hovered { hovered = h; needsDisplay = true }
        // Text fields keep their own I-beam.
        if h != nil { NSCursor.pointingHand.set() } else if !subviews.contains(where: { !$0.isHidden && $0.frame.contains(p) }) { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let action = regions.last(where: { $0.rect.contains(p) })?.action else {
            window?.makeFirstResponder(self)
            window?.performDrag(with: event)
            return
        }
        handle(action)
        needsDisplay = true
    }

    // MARK: Controls

    /// A small uppercase section label.
    func sectionLabel(_ s: String, x: CGFloat, y: CGFloat, ctx: CGContext) {
        Text(s, F.sf(9.5, 700), theme.muted2, kern: 0.9).draw(x: x + 1, capCenter: y + 4, in: ctx)
    }

    /// Pill segments whose widths follow their labels, then share the spare room evenly.
    func segmented(_ items: [String], selected: Int, x: CGFloat, y: CGFloat, w: CGFloat, actions: [AnyHashable], enabled: Bool = true, ctx: CGContext) {
        let t = theme
        let r = CGRect(x: x, y: y, width: w, height: 30)
        ctx.withState {
            if !enabled { ctx.setAlpha(0.4); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            let track = rounded(r, 10)
            ctx.fill(track, t.segmentTrack)
            if t.isDark { ctx.innerStroke(track, t.segmentTrackBorder, width: 0.5) }
            let font = F.sf(12, 600)
            let natural = items.map { Text($0, font, .black).width + 16 }
            let spare = max(0, (w - 4) - natural.reduce(0, +)) / CGFloat(items.count)
            var sx = r.minX + 2
            for (i, item) in items.enumerated() {
                let sw = natural[i] + spare
                let seg = CGRect(x: sx, y: r.minY + 2, width: sw, height: r.height - 4)
                if i == selected {
                    let s = rounded(seg, 8)
                    ctx.withState {
                        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: (t.isDark ? black(0.35) : black(0.12)).cgColor)
                        ctx.fill(s, t.isDark ? rgb(0x2E2F34) : .white)
                    }
                    ctx.fillVertical(s, t.segmentOnTop, t.segmentOnBottom)
                } else if enabled && hovered == actions[i] {
                    ctx.fill(rounded(seg, 8), t.isDark ? white(0.04) : white(0.5))
                }
                Text(item, font, t.ink.fade(i == selected ? 1 : 0.55)).draw(x: seg.midX, capCenter: seg.midY, align: .center, in: ctx)
                if enabled { regions.append((seg, actions[i])) }
                sx += sw
            }
            if !enabled { ctx.endTransparencyLayer() }
        }
    }

    /// A title, a line of detail and a switch on the right; the whole row toggles.
    func toggleRow(_ title: String, _ detail: String, on: Bool, action: some Hashable, x: CGFloat, y: CGFloat, w: CGFloat,
                   enabled: Bool = true, ctx: CGContext) {
        let t = theme
        let r = CGRect(x: x, y: y, width: w, height: 40)
        ctx.withState {
            if !enabled { ctx.setAlpha(0.4); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            if enabled && isHovered(action) { ctx.fill(rounded(r.insetBy(dx: -8, dy: -2), 10), t.isDark ? white(0.035) : black(0.025)) }
            Text(title, F.sf(13, 600), t.ink).draw(x: x, capCenter: r.minY + 12, in: ctx)
            Text(detail, F.sf(12), t.muted).draw(x: x, capCenter: r.minY + 30, in: ctx)
            drawSwitch(on: on, rect: CGRect(x: r.maxX - 36, y: r.midY - 11, width: 36, height: 22), ctx: ctx)
            if !enabled { ctx.endTransparencyLayer() }
        }
        if enabled { hit(r.insetBy(dx: -8, dy: -2), action) }
    }

    func drawSwitch(on: Bool, rect: CGRect, ctx: CGContext) {
        let t = theme
        let track = rounded(rect, rect.height / 2)
        if on {
            let c = t.pacing(.plenty)
            ctx.glow(track, color: c.glow.fade(0.7), blur: 8, base: c.bottom)
            ctx.fillVertical(track, c.top, c.bottom)
        } else {
            ctx.fill(track, t.isDark ? white(0.13) : black(0.11))
            ctx.innerStroke(track, t.isDark ? white(0.06) : black(0.04), width: 0.5)
        }
        let d = rect.height - 4
        let knob = CGRect(x: on ? rect.maxX - 2 - d : rect.minX + 2, y: rect.minY + 2, width: d, height: d)
        let k = CGMutablePath(); k.addEllipse(in: knob)
        ctx.withState {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: black(0.3).cgColor)
            ctx.fill(k, .white)
        }
    }

    func drawCheck(on: Bool, center c: CGPoint, tint: NSColor, ctx: CGContext) {
        let t = theme
        let r = CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)
        let circle = CGMutablePath(); circle.addEllipse(in: r)
        if on {
            ctx.withState {
                ctx.setShadow(offset: .zero, blur: 8, color: tint.fade(0.6).cgColor)
                ctx.fill(circle, tint)
            }
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: c.x - 5, y: c.y + 0.5))
            tick.addLine(to: CGPoint(x: c.x - 1.5, y: c.y + 4))
            tick.addLine(to: CGPoint(x: c.x + 5.5, y: c.y - 4))
            ctx.stroke(tick, .white, width: 2.2, cap: .round, join: .round)
        } else {
            ctx.stroke(CGPath(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75), transform: nil), t.isDark ? white(0.25) : black(0.2), width: 1.5)
        }
    }

    enum ButtonStyle { case primary, plain, tinted }

    /// A button right-aligned at `right`: primary (ink pill), plain (text) or tinted (soft pill). Returns its rect.
    @discardableResult
    func button(_ title: String, right: CGFloat, mid: CGFloat, style: ButtonStyle, enabled: Bool = true, height: CGFloat = 34,
                action: some Hashable, ctx: CGContext) -> CGRect {
        let t = theme
        let font = F.sf(height < 30 ? 12 : 13, 650)
        let label = Text(title, font, .black)
        let padX: CGFloat = height < 30 ? 24 : 36
        let r = CGRect(x: right - label.width - padX, y: mid - height / 2, width: label.width + padX, height: height)
        let shape = rounded(r, height < 30 ? 8.5 : 11)
        let hover = isHovered(action) && enabled
        switch style {
        case .primary:
            let (top, bottom, ink): (NSColor, NSColor, NSColor) = t.isDark
                ? (white(hover ? 1 : 0.97), rgb(hover ? 0xE2E4EA : 0xD3D6DD), rgb(0x16171B))
                : (rgb(hover ? 0x3A3C42 : 0x2C2E33), rgb(0x16171B), white(1))
            ctx.withState {
                ctx.setAlpha(enabled ? 1 : 0.35)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.withState {
                    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: black(t.isDark ? 0.4 : 0.18).cgColor)
                    ctx.fill(shape, bottom)
                }
                ctx.fillVertical(shape, top, bottom)
                Text(title, font, ink).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
                ctx.endTransparencyLayer()
            }
        case .tinted:
            ctx.withState {
                ctx.setAlpha(enabled ? 1 : 0.4)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.withState {
                    if !t.isDark { ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: black(0.08).cgColor) }
                    ctx.fill(shape, t.isDark ? white(hover ? 0.13 : 0.09) : (hover ? rgb(0xFAFAFC) : .white))
                }
                ctx.innerStroke(shape, t.isDark ? white(0.08) : black(0.07), width: 0.5)
                Text(title, font, t.ink).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
                ctx.endTransparencyLayer()
            }
        case .plain:
            if hover { ctx.fill(shape, t.isDark ? white(0.07) : black(0.05)) }
            Text(title, font, t.muted).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        }
        if enabled { hit(r, action) }
        return r
    }

    /// A provider choice: brand tile, name, a status line and a check. The whole card toggles.
    func providerCard(_ p: Provider, on: Bool, status: (text: String, good: Bool?), rect r: CGRect, action: some Hashable, ctx: CGContext) {
        let t = theme
        let hover = isHovered(action)
        let shape = rounded(r, 16)
        let brand = Brand.of(p)
        ctx.fill(shape, t.isDark ? white(hover ? 0.07 : 0.045) : (hover ? rgb(0xFAFAFC) : .white))
        if on {
            ctx.fillRadial(in: shape, center: CGPoint(x: r.minX, y: r.minY), radii: CGSize(width: 260, height: 120),
                           color: t.isDark ? brand.orbDark : brand.orbLight, fadeAt: 0.8)
            ctx.innerStroke(shape, brand.base.fade(t.isDark ? 0.75 : 0.6), width: 1.5)
        } else {
            ctx.innerStroke(shape, t.isDark ? white(0.08) : black(0.08), width: 1)
        }
        let side = min(40, r.height - 24)
        BrandMark.drawTile(p, in: CGRect(x: r.minX + 16, y: r.midY - side / 2, width: side, height: side), ctx: ctx)
        let tx = r.minX + 16 + side + 14
        Text(p == .claude ? "Claude Code" : "Codex", F.sf(14.5, 650), t.ink, kern: -0.1).draw(x: tx, capCenter: r.midY - 9, in: ctx)
        let sc: NSColor = status.good == true ? t.ok : (status.good == false ? t.amber : t.muted2)
        drawStatusDot(center: CGPoint(x: tx + 3, y: r.midY + 11), color: sc, ctx: ctx)
        Text(status.text, F.sf(12, 500), t.muted).draw(x: tx + 13, capCenter: r.midY + 11, in: ctx)
        drawCheck(on: on, center: CGPoint(x: r.maxX - 26, y: r.midY), tint: brand.base, ctx: ctx)
        hit(r, action)
    }

    /// An SF Symbol, tinted, drawn into the canvas.
    static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, weight: NSFont.Weight = .semibold, ctx: CGContext) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        // Fit the symbol's own aspect inside the box.
        let s = image.size
        let k = min(rect.width / max(s.width, 1), rect.height / max(s.height, 1))
        let box = CGRect(x: rect.midX - s.width * k / 2, y: rect.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// What Headroom knows about a provider so far, as a status line (welcome and Settings).
@MainActor
enum ProviderStatusLine {
    enum State { case signedIn(plan: String?), fault(Fault) }

    static func text(_ p: Provider, state: State?, enabled: Bool) -> (text: String, good: Bool?) {
        switch state {
        case .signedIn(let plan)?:
            return ("Signed in" + (plan.map { " · \($0)" } ?? ""), true)
        case .fault(let f)?:
            switch f {
            case .cliMissing: return ("Not found on this Mac", false)
            case .signedOut: return ("Found · signed out", false)
            case .enterprise, .apiKeyLogin: return ("No plan limits · cost only", nil)
            default: return ("Found · will retry", nil)
            }
        case nil: break
        }
        let dir = p == .claude ? ".claude" : ".codex"
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dir)
        if FileManager.default.fileExists(atPath: home.path) {
            return (enabled ? "Found · reading limits…" : "Found on this Mac", nil)
        }
        return ("Not set up yet · add it any time", nil)
    }

    static func state(_ p: Provider, model: AppModel?) -> State? {
        guard let model else { return nil }
        if let r = model.faults[p]?.lastGood { return .signedIn(plan: r.plan?.pill) }
        return model.faults[p]?.fault.map { .fault($0) }
    }
}
