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

        let glass = NSGlassEffectView()
        glass.cornerRadius = PopoverChrome.radius
        glass.style = .regular
        let root = PopoverRootView(model: model, controller: self)
        glass.contentView = root
        panel.contentView = glass
        self.panel = panel
        self.root = root
        model.popoverOpen = true
        root.rebuild(animated: false)
        applyTint(glass)

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        position(panel, under: buttonRect, height: root.preferredHeight)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func applyTint(_ glass: NSGlassEffectView) {
        let theme = Theme.current(for: glass.effectiveAppearance)
        glass.tintColor = theme.windowFill.withAlphaComponent(theme.isDark ? 0.86 : 0.82)
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
    }

    /// Called when the model changed.
    func refresh() {
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
    private let scroll = NSScrollView()
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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = cards
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
    }

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
        layoutScroll()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutScroll()
    }

    private func layoutScroll() {
        let h = max(bounds.height - topHeight - bottomHeight, 40)
        scroll.frame = NSRect(x: 0, y: topHeight, width: bounds.width, height: h)
        cards.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(cards.contentHeight, h))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let glass = superview as? NSGlassEffectView { controller?.applyTint(glass) }
        needsDisplay = true
        cards.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = theme
        out = RenderOutput()
        removeAllToolTips()
        PopoverChrome.drawWindow(bounds, theme: t, ctx: ctx, opaque: false)
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
        for r in out.regions where r.tooltip != nil { addToolTip(r.rect, owner: self, userData: nil) }
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
    var tab = 0
    /// Selected bar range for the Activity span (shared by both providers).
    var selection: Range<Int>?
    var historyWeek: (provider: Provider, index: Int)?
    private(set) var contentHeight: CGFloat = 200

    private var paceCards: [PaceCardModel] = []
    private var activityCards: [ActivityCardModel] = []
    private var weeks: [PastWeeksModel] = []
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
    var theme: Theme { Theme.current(for: effectiveAppearance) }

    func rebuild(animated: Bool) {
        let now = Date()
        let presenter = Presenter(now: now)
        paceCards = model.paceInputs().map { presenter.paceCard($0) }
        let states = paceCards.map { $0.meter?.state }
        if tab == 1 || historyWeek != nil {
            let ap = ActivityPresenter(now: now, pricing: model.pricingEngine)
            let aggregates = model.aggregates()
            let range = model.settings.activityRange
            activityCards = model.settings.enabledProviders.sorted().map { ap.card($0, aggregates: aggregates, range: range, selection: selection) }
            weeks = model.settings.enabledProviders.sorted().map { pastWeeks($0, presenter: presenter) }
        }
        contentHeight = measure()
        if animated, states != lastStates, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "stateFade")
        }
        lastStates = states
        needsDisplay = true
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
        return y + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        out = RenderOutput()
        removeAllToolTips()
        layout(ctx: ctx, width: bounds.width)
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

    private func barIndex(_ p: NSPoint, provider: Provider) -> Int? {
        guard let l = chartLayouts[provider], l.barCount > 0, l.chartRect.insetBy(dx: 0, dy: -6).contains(p) else { return nil }
        return min(max(Int((p.x - l.chartRect.minX) / l.barWidth), 0), l.barCount - 1)
    }

    private func provider(at p: NSPoint) -> Provider? { cardRects.first { $0.1.contains(p) }?.0 }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let region = out.regions.last(where: { $0.rect.contains(p) && $0.action != .none }) {
            switch region.action {
            case .breakdownMenu: showBreakdownMenu(at: p); return
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
        let p = convert(event.locationInWindow, from: nil)
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
        let p = convert(event.locationInWindow, from: nil)
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
        let presenter = Presenter(now: now)
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
