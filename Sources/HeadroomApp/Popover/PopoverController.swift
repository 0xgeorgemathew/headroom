import AppKit
import HeadroomCore
import HeadroomKit

/// The popover: a borderless glass panel under the status item. Built on open, torn down on close.
@MainActor
final class PopoverController: NSObject {
    let model: AppModel
    var openSettings: (() -> Void)?
    private var panel: NSPanel?
    private var root: PopoverRootView?
    private var monitors: [Any] = []
    var isShown: Bool { panel != nil }

    init(model: AppModel) {
        self.model = model
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard panel == nil, let buttonWindow = button.window else { return }
        let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: PopoverChrome.width, height: 400),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow
        panel.appearance = model.settings.appearance.nsAppearance

        // The surface is drawn by PopoverRootView (the mockup's opaque window with a top sheen).
        // NSGlassEffectView and NSVisualEffectView both render in-process with Metal and map a
        // ~190 MB shader archive on open (measured: 163–171 MB peaks vs 35 MB drawn), which breaks
        // the popover memory budget (PLAN §4.4).
        let root = PopoverRootView(model: model, controller: self)
        // A plain container: a layer-backed `updateLayer` view as the content view itself leaves
        // the window without a server-side surface (AppKit reports it visible; nothing appears).
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.frame = container.bounds
        root.autoresizingMask = [.width, .height]
        container.addSubview(root)
        panel.contentView = container
        self.panel = panel
        self.root = root
        model.popoverOpen = true
        root.rebuild(animated: false)

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        position(panel, under: buttonRect, height: root.preferredHeight)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installMonitors()
    }

    private func position(_ panel: NSPanel, under buttonRect: NSRect, height: CGFloat) {
        let screen = NSScreen.screens.first { $0.frame.contains(buttonRect.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = min(height, visible.height - 16)
        var x = buttonRect.midX - PopoverChrome.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - PopoverChrome.width - 8)
        let y = buttonRect.minY - 6 - h
        panel.setFrame(NSRect(x: x, y: y, width: PopoverChrome.width, height: h), display: true)
    }

    /// Re-fits the panel after content changes, keeping its top edge fixed.
    func resize(to height: CGFloat) {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let h = min(height, visible.height - 16)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true)
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        root = nil
        model.popoverOpen = false
        // Give back the drawing buffers now and again once AppKit has torn the panel down.
        Memory.relieve()
    }

    /// Called when the model changed.
    func refresh() {
        if let panel, panel.appearance != model.settings.appearance.nsAppearance { panel.appearance = model.settings.appearance.nsAppearance }
        root?.rebuild(animated: true)
    }

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.close() }; return nil }
            return event
        }) { monitors.append(m) }
    }
}

final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Root view

/// Fixed header (and Activity controls), a scrolling card stack, fixed footer.
@MainActor
final class PopoverRootView: NSView, NSViewToolTipOwner {
    let model: AppModel
    weak var controller: PopoverController?
    private let cards: CardsView
    private var out = RenderOutput()
    var tab: Int { didSet { model.settings.lastTab = tab } }

    init(model: AppModel, controller: PopoverController) {
        self.model = model
        self.controller = controller
        self.tab = model.settings.lastTab
        cards = CardsView(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: PopoverChrome.width, height: 400))
        cards.root = self
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(cards)
    }

    override var wantsUpdateLayer: Bool { true }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var theme: Theme { Theme.current(for: effectiveAppearance) }

    var topHeight: CGFloat { PopoverChrome.pad + PopoverChrome.headerHeight + (tab == 1 && cards.historyWeek == nil ? 36 : 0) }
    var bottomHeight: CGFloat { PopoverChrome.footerHeight + PopoverChrome.pad }

    var preferredHeight: CGFloat { topHeight + cards.contentHeight + bottomHeight }

    func rebuild(animated: Bool) {
        cards.tab = tab
        cards.rebuild(animated: animated)
        controller?.resize(to: preferredHeight)
        layoutCards()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    /// The card view is only as tall as the visible area and scrolls itself, so no tall backing
    /// store exists (a tall one gets GPU tiling, which maps CoreAnimation's Metal archive).
    private func layoutCards() {
        let h = max(bounds.height - topHeight - bottomHeight, 40)
        cards.frame = NSRect(x: 0, y: topHeight, width: bounds.width, height: h)
        cards.clampOffset()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        cards.needsDisplay = true
    }

    override func updateLayer() {
        CPUCanvas.update(self) { ctx in self.drawContent(ctx) }
        for r in out.regions where r.tooltip != nil { addToolTip(r.rect, owner: self, userData: nil) }
    }

    private func drawContent(_ ctx: CGContext) {
        let t = theme
        removeAllToolTips()
        PopoverChrome.drawWindow(bounds, theme: t, ctx: ctx, opaque: true)
        let pad = PopoverChrome.pad, cw = bounds.width - pad * 2
        if let week = cards.historyWeek {
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, title: "Headroom", tabs: ["Back"], selected: -1, theme: t, ctx: ctx, out: out)
            out.regions = out.regions.map { var r = $0; if case .tab = r.action { r.action = .tab(-1) }; return r }
            _ = week
        } else {
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, selected: tab, theme: t, ctx: ctx, out: out)
        }
        if tab == 1 && cards.historyWeek == nil {
            let y = pad + PopoverChrome.headerHeight
            let modes = Segmented(items: ["All", "New only"], selected: model.settings.activityMode.rawValue, font: F.sf(11.5, 600), padX: 10, height: 26)
            modes.draw(in: CGRect(x: pad + 1, y: y, width: modes.width, height: 26), theme: t, ctx: ctx, out: out) { .activityMode($0) }
            let ranges = Segmented(items: ActivityRange.allCases.map(\.label), selected: model.settings.activityRange.rawValue, font: F.sf(11.5, 600), padX: 10, height: 26)
            ranges.draw(in: CGRect(x: pad + cw - 1 - ranges.width, y: y, width: ranges.width, height: 26), theme: t, ctx: ctx, out: out) { .activityRange($0) }
        }
        PopoverChrome.drawFooter(model.footer, x: pad, y: bounds.height - bottomHeight, width: cw, theme: t, ctx: ctx, out: out)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        out.regions.first { $0.rect.contains(point) && $0.tooltip != nil }?.tooltip ?? ""
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let region = out.regions.last(where: { $0.rect.contains(p) && $0.action != .none }) else { return }
        switch region.action {
        case .tab(let i):
            if i < 0 { cards.historyWeek = nil } else { tab = i }
            rebuild(animated: false)
        case .activityMode(let i):
            model.settings.activityMode = ActivityMode(rawValue: i) ?? .all
            rebuild(animated: false)
        case .activityRange(let i):
            model.settings.activityRange = ActivityRange(rawValue: i) ?? .day
            cards.selection = nil
            rebuild(animated: false)
        case .refresh:
            model.refreshNow()
        case .settings:
            controller?.close()
            controller?.openSettings?()
        default: break
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Cards

@MainActor
final class CardsView: NSView, NSViewToolTipOwner {
    let model: AppModel
    weak var root: PopoverRootView?
    var tab = 0 { didSet { if tab != oldValue { offset = 0 } } }
    /// Scroll position within the card stack.
    private(set) var offset: CGFloat = 0
    /// Selected bar range for the Activity span (shared by both providers).
    var selection: Range<Int>?
    var historyWeek: (provider: Provider, index: Int)?
    private(set) var contentHeight: CGFloat = 200

    private var paceCards: [PaceCardModel] = []
    private var activityCards: [ActivityCardModel] = []
    private var weeks: [PastWeeksModel] = []
    private var sessionHistories: [SessionHistoryModel] = []
    private var weekRecords: [Provider: [WeekRecord]] = [:]
    private var out = RenderOutput()
    private var chartLayouts: [Provider: ActivityCardRenderer.Layout] = [:]
    private var cardRects: [(Provider, CGRect)] = []
    private var dragAnchor: Int?
    private var lastStates: [PacingState?] = []

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    var theme: Theme { Theme.current(for: effectiveAppearance) }

    func rebuild(animated: Bool) {
        let now = Date()
        let presenter = model.presenter(now: now)
        paceCards = model.paceInputs().map { presenter.paceCard($0) }
        let states = paceCards.map { $0.meter?.state }
        if tab == 1 || historyWeek != nil {
            let ap = ActivityPresenter(now: now, pricing: model.pricingEngine)
            let aggregates = model.aggregates()
            let range = model.settings.activityRange
            activityCards = model.settings.enabledProviders.sorted().map { ap.card($0, aggregates: aggregates, range: range, selection: selection) }
            weeks = model.settings.enabledProviders.sorted().map { pastWeeks($0, presenter: presenter) }
            sessionHistories = model.settings.enabledProviders.sorted().compactMap { p in
                let input = model.paceInput(p)
                guard let reading = input.reading, reading.session != nil else { return nil }
                let sessions = model.history.account(p, reading.accountKey)?.recentSessions(now: now) ?? []
                return SessionHistoryRenderer.model(p, sessions: sessions, warnAt: model.settings.sessionWarnAt, now: now)
            }
        }
        if animated, states != lastStates, !lastStates.isEmpty, window != nil { beginFade() }
        contentHeight = measure()
        lastStates = states
        needsDisplay = true
    }

    // MARK: State cross-fade (PLAN §3.4: 150 ms when the state changes), drawn on the CPU.

    private var fade: (image: CGImage, rect: NSRect, start: Date)?
    private var fadeTimer: Timer?

    private func beginFade() {
        let rect = bounds.integral
        guard let image = CPUCanvas.image(for: self, rect: rect, { ctx in
            ctx.translateBy(x: 0, y: -self.offset)
            _ = self.layout(ctx: ctx, width: self.bounds.width)
        }) else { return }
        fade = (image, rect, Date())
        fadeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let f = self.fade else { return }
                if Date().timeIntervalSince(f.start) >= 0.15 { self.fade = nil; self.fadeTimer?.invalidate(); self.fadeTimer = nil }
                _ = f
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func pastWeeks(_ p: Provider, presenter: Presenter) -> PastWeeksModel {
        let input = model.paceInput(p)
        let acct = input.reading.flatMap { model.history.account(p, $0.accountKey) }
        let records = Array((acct?.weeks ?? []).suffix(7))
        weekRecords[p] = records
        guard records.count >= 1, let reading = input.reading, let headline = reading.headline, headline.resetsAt != nil else {
            return PastWeeksModel(provider: p, weeks: [], planChange: nil, chips: [], collecting: true)
        }
        let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: Date())
        var cols = records.map { r in
            WeekColumn(used: r.finalUsed, ranOutHoursEarly: r.hoursEarly, sessionHits: r.sessionHits, earlyResets: r.earlyReset ? 1 : 0,
                       caption: "Week to \(TimeFormat.monthDay(r.scheduledEnd, calendar: .current, locale: .current)) · \(Int((r.finalUsed * 100).rounded()))% used")
        }
        let projected: Double = a.projectedRunOut.map { $0 < a.resetsAt ? 1 : 1 - (a.projectedUnusedAtReset ?? 0) } ?? (1 - (a.projectedUnusedAtReset ?? a.remaining))
        cols.append(WeekColumn(used: 1 - a.remaining, projected: max(projected, 1 - a.remaining), sessionHits: acct?.sessionHitsThisWindow ?? 0,
                               earlyResets: acct?.earlyResetAt != nil ? 1 : 0, isCurrent: true, caption: "This week · \(Int(((1 - a.remaining) * 100).rounded()))% used so far"))
        var change: (after: Int, pill: String)? = nil
        let plans = records.map(\.plan) + [reading.plan?.pill]
        for i in 1..<plans.count where plans[i] != plans[i - 1] && plans[i] != nil && plans[i - 1] != nil { change = (i - 1, plans[i] ?? "") }
        let ranOut = records.filter(\.ranOut).count
        var chips: [(color: PastWeeksModel.ChipDot, text: String)] = [(.rose, "ran out \(ranOut) of \(records.count)")]
        let early = records.filter(\.earlyReset).count
        if early > 0 {
            chips.append((.spark, "\(early) early reset\(early == 1 ? "" : "s")"))
        } else {
            let unused = records.map { max(0, 1 - $0.finalUsed) }.reduce(0, +) / Double(records.count)
            chips.append((.azure, "\(Int((unused * 100).rounded()))% unused avg"))
        }
        return PastWeeksModel(provider: p, weeks: cols, planChange: change, chips: chips, collecting: false)
    }

    private func measure() -> CGFloat {
        let w = bounds.width > 0 ? bounds.width : PopoverChrome.width
        return layout(ctx: nil, width: w)
    }

    /// Lays out (and draws when ctx != nil) the card stack. Returns the height.
    @discardableResult
    private func layout(ctx: CGContext?, width: CGFloat) -> CGFloat {
        let pad = PopoverChrome.pad, cw = width - pad * 2, t = theme
        var y: CGFloat = 0
        cardRects.removeAll()
        if let week = historyWeek, let records = weekRecords[week.provider], week.index < records.count || week.index == records.count {
            let h = HistoryCardRenderer.draw(provider: week.provider, record: week.index < records.count ? records[week.index] : nil,
                                             origin: CGPoint(x: pad, y: y), width: cw, theme: t, ctx: ctx)
            cardRects.append((week.provider, CGRect(x: pad, y: y, width: cw, height: h)))
            return y + h + 4
        }
        if tab == 0 {
            if paceCards.isEmpty {
                let h: CGFloat = 80
                if let ctx {
                    CardChrome.draw(CGRect(x: pad, y: y, width: cw, height: h), provider: nil, theme: t, ctx: ctx)
                    Text("Both providers are turned off in Settings.", F.sf(13, 500), t.muted).draw(x: pad + cw / 2, capCenter: y + h / 2, align: .center, in: ctx)
                }
                return h
            }
            for (i, card) in paceCards.enumerated() {
                if i > 0 { y += 10 }
                let h = PaceCardRenderer.draw(card, origin: CGPoint(x: pad, y: y), width: cw, theme: t, ctx: ctx, out: ctx == nil ? nil : out)
                cardRects.append((card.provider, CGRect(x: pad, y: y, width: cw, height: h)))
                y += h
            }
            return y + 2
        }
        let mode = model.settings.activityMode, kind = model.settings.breakdown
        for (i, card) in activityCards.enumerated() {
            if i > 0 { y += 10 }
            var layout = ActivityCardRenderer.Layout()
            let h = ActivityCardRenderer.draw(card, mode: mode, breakdown: kind, origin: CGPoint(x: pad, y: y), width: cw, theme: t, ctx: ctx,
                                              out: ctx == nil ? nil : out, layout: &layout)
            chartLayouts[card.provider] = layout
            cardRects.append((card.provider, CGRect(x: pad, y: y, width: cw, height: h)))
            y += h
        }
        y += 16
        if let ctx { PastWeeksRenderer.drawSectionHeader(x: pad, y: y, width: cw, theme: t, ctx: ctx) }
        y += PastWeeksRenderer.sectionHeaderHeight
        for (i, wk) in weeks.enumerated() {
            if i > 0 { y += 10 }
            let h = PastWeeksRenderer.draw(wk, origin: CGPoint(x: pad, y: y), width: cw, theme: t, ctx: ctx, out: ctx == nil ? nil : out)
            cardRects.append((wk.provider, CGRect(x: pad, y: y, width: cw, height: h)))
            y += h
        }
        if weeks.contains(where: { !$0.collecting }) {
            if let ctx { PastWeeksRenderer.drawLegend(x: pad, y: y, width: cw, theme: t, ctx: ctx) }
            y += PastWeeksRenderer.legendHeight
        }
        if !sessionHistories.isEmpty {
            y += 6
            if let ctx { SessionHistoryRenderer.drawSectionHeader(x: pad, y: y, width: cw, warnAt: model.settings.sessionWarnAt, theme: t, ctx: ctx) }
            y += SessionHistoryRenderer.sectionHeaderHeight
            for (i, sh) in sessionHistories.enumerated() {
                if i > 0 { y += 10 }
                let h = SessionHistoryRenderer.draw(sh, origin: CGPoint(x: pad, y: y), width: cw, theme: t, ctx: ctx, out: ctx == nil ? nil : out)
                cardRects.append((sh.provider, CGRect(x: pad, y: y, width: cw, height: h)))
                y += h
            }
            y += 4
        }
        return y + 2
    }

    override func updateLayer() {
        out = RenderOutput()
        removeAllToolTips()
        let fadeAlpha = fade.map { 1 - min(1, Date().timeIntervalSince($0.start) / 0.15) }
        CPUCanvas.update(self) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: 0, y: -self.offset)
            self.layout(ctx: ctx, width: self.bounds.width)
            ctx.restoreGState()
            if let f = self.fade, let a = fadeAlpha {
                ctx.saveGState()
                ctx.setAlpha(a)
                ctx.translateBy(x: f.rect.minX, y: f.rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(f.image, in: CGRect(origin: .zero, size: f.rect.size))
                ctx.restoreGState()
            }
        }
        // Regions were recorded in content coordinates; move them into view coordinates.
        out.regions = out.regions.map { var r = $0; r.rect = r.rect.offsetBy(dx: 0, dy: -offset); return r }
        for r in out.regions where r.tooltip != nil { addToolTip(r.rect, owner: self, userData: nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        out.regions.first { $0.rect.contains(point) && $0.tooltip != nil }?.tooltip ?? ""
    }

    // MARK: Mouse

    func clampOffset() {
        let maxOffset = max(0, contentHeight - bounds.height)
        offset = min(max(offset, 0), maxOffset)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let before = offset
        offset -= dy
        clampOffset()
        if offset != before { needsDisplay = true }
    }

    /// View point → content point.
    private func content(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x, y: p.y + offset) }

    private func barIndex(_ p: NSPoint, provider: Provider) -> Int? {
        guard let l = chartLayouts[provider], l.barCount > 0, l.chartRect.insetBy(dx: 0, dy: -6).contains(p) else { return nil }
        return min(max(Int((p.x - l.chartRect.minX) / l.barWidth), 0), l.barCount - 1)
    }

    private func provider(at p: NSPoint) -> Provider? { cardRects.first { $0.1.contains(p) }?.0 }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let p = content(v)
        if let region = out.regions.last(where: { $0.rect.contains(v) && $0.action != .none }) {
            switch region.action {
            case .breakdownMenu: showBreakdownMenu(at: v); return
            case .openWeek(let prov, let i):
                historyWeek = (prov, i)
                root?.rebuild(animated: false)
                return
            default: break
            }
        }
        guard tab == 1, let prov = provider(at: p), let i = barIndex(p, provider: prov) else { return }
        let n = chartLayouts[prov]?.barCount ?? 0
        if event.clickCount == 2 {
            selection = i..<n
            dragAnchor = nil
            root?.rebuild(animated: false)
            return
        }
        // Grab an existing handle, or start a new selection.
        if let s = selection ?? .some(0..<n), abs(i - s.lowerBound) <= 0 && s.count > 1 { dragAnchor = s.upperBound - 1 }
        else if let s = selection ?? .some(0..<n), abs(i - (s.upperBound - 1)) <= 0 && s.count > 1 { dragAnchor = s.lowerBound }
        else { dragAnchor = i }
        selection = min(dragAnchor!, i)..<(max(dragAnchor!, i) + 1)
        root?.rebuild(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = content(convert(event.locationInWindow, from: nil))
        guard tab == 1, let anchor = dragAnchor else { return }
        let prov = provider(at: p) ?? chartLayouts.keys.sorted().first!
        guard let l = chartLayouts[prov], l.barCount > 0 else { return }
        let i = min(max(Int((p.x - l.chartRect.minX) / l.barWidth), 0), l.barCount - 1)
        let s = min(anchor, i)..<(max(anchor, i) + 1)
        if s != selection {
            selection = s
            root?.rebuild(animated: false)
        }
    }

    override func mouseUp(with event: NSEvent) { dragAnchor = nil }

    private func showBreakdownMenu(at p: NSPoint) {
        let menu = NSMenu()
        for kind in BreakdownKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(pickBreakdown(_:)), keyEquivalent: "")
            item.tag = kind.rawValue
            item.target = self
            item.state = kind == model.settings.breakdown ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }

    @objc private func pickBreakdown(_ sender: NSMenuItem) {
        model.settings.breakdown = BreakdownKind(rawValue: sender.tag) ?? .model
        root?.rebuild(animated: false)
    }

    // MARK: Share menu (right-click)

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = content(convert(event.locationInWindow, from: nil))
        guard let prov = provider(at: p) else { return nil }
        let menu = NSMenu()
        for (title, sel) in [("Copy Card", #selector(copyCard(_:))), ("Copy Snapshot", #selector(copySnapshot(_:))), ("Copy as Text", #selector(copyText(_:)))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.representedObject = prov.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func shares() -> [ShareModel] {
        ShareFactory(model: model, selection: selection).shares()
    }

    @objc private func copyCard(_ sender: NSMenuItem) {
        guard let p = (sender.representedObject as? String).flatMap(Provider.init(rawValue:)),
              let share = shares().first(where: { $0.provider == p }), let rep = ShareCardRenderer.card(share) else { return }
        Pasteboard.copy(image: rep)
    }

    @objc private func copySnapshot(_ sender: NSMenuItem) {
        guard let rep = ShareCardRenderer.snapshot(shares()) else { return }
        Pasteboard.copy(image: rep)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let p = (sender.representedObject as? String).flatMap(Provider.init(rawValue:)) else { return }
        Pasteboard.copy(text: ShareBuilder.text(shares().filter { $0.provider == p }))
    }
}

enum Pasteboard {
    @MainActor static func copy(image rep: NSBitmapImageRep) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    @MainActor static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Assembles share models from live state (selected Activity span + pace).
@MainActor
struct ShareFactory {
    let model: AppModel
    let selection: Range<Int>?

    func shares() -> [ShareModel] {
        let now = Date()
        let ap = ActivityPresenter(now: now, pricing: model.pricingEngine)
        let presenter = model.presenter(now: now)
        let aggregates = model.aggregates()
        let range = model.settings.activityRange
        return model.settings.enabledProviders.sorted().map { p in
            let card = ap.card(p, aggregates: aggregates, range: range, selection: selection)
            let input = model.paceInput(p)
            let pace = presenter.paceCard(input)
            let span = card.bars.isEmpty ? (now, now) : (card.bars[card.selection.lowerBound].start, min(card.bars[card.selection.upperBound - 1].end, now))
            let used = allowanceUsed(input, from: span.0, to: span.1)
            return ShareBuilder.make(activity: card, pace: pace, mode: model.settings.activityMode, includeCost: model.settings.costOnShares,
                                     burnInSpan: used, durationText: TimeFormat.spokenSpan(span.1.timeIntervalSince(span.0)))
        }
    }

    /// Share of the weekly allowance used over the span, from glide samples (nil when unknown).
    private func allowanceUsed(_ input: PaceInput, from a: Date, to b: Date) -> Double? {
        guard let h = input.reading?.headline, let samples = input.samples[h.id], samples.count >= 2,
              let start = h.windowStart, a >= start else { return nil }
        func used(at t: Date) -> Double? {
            guard let after = samples.firstIndex(where: { $0.time >= t }) else { return samples.last?.used }
            if after == 0 { return samples[0].used }
            let s0 = samples[after - 1], s1 = samples[after]
            let f = s1.time.timeIntervalSince(s0.time) > 0 ? t.timeIntervalSince(s0.time) / s1.time.timeIntervalSince(s0.time) : 0
            return s0.used + (s1.used - s0.used) * f
        }
        guard let ua = used(at: a), let ub = used(at: b) else { return nil }
        return max(0, ub - ua)
    }
}
