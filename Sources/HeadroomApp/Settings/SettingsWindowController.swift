import AppKit
import HeadroomCore
import HeadroomKit
import ServiceManagement
import UserNotifications

/// Settings: drawn like the welcome window. A sidebar of sections, the choices in the middle, and a
/// live preview on the right. Every control writes through to `AppSettings` at once.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings
    private let view: SettingsView
    var openWelcome: (() -> Void)? {
        get { view.openWelcome }
        set { view.openWelcome = newValue }
    }

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        view = SettingsView(settings: settings, model: model)
        let size = SettingsView.size
        let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Headroom Settings"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = settings.appearance.nsAppearance
        // A plain container: the drawn view is layer-backed and sets its own contents (see PopoverController).
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(section: Int? = nil) {
        if let section { view.select(SettingsView.Section.allCases[min(max(section, 0), SettingsView.Section.allCases.count - 1)], animated: false) }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }

    /// Settings or readings changed elsewhere.
    func refresh() {
        if window?.appearance != settings.appearance.nsAppearance { window?.appearance = settings.appearance.nsAppearance }
        view.syncFields()
        view.needsDisplay = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        view.refreshStatuses()
    }
}

// MARK: - The drawn view

@MainActor
final class SettingsView: CanvasControlView, NSTextFieldDelegate {
    static let size = NSSize(width: 968, height: 640)
    static let sidebarWidth: CGFloat = 212
    static let stageWidth: CGFloat = 320

    enum Section: Int, CaseIterable, Hashable {
        case general, menuBar, card, session, notifications, advanced

        var title: String {
            switch self {
            case .general: "General"
            case .menuBar: "Menu Bar"
            case .card: "Pace Card"
            case .session: "5-Hour Session"
            case .notifications: "Notifications"
            case .advanced: "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .menuBar: "menubar.rectangle"
            case .card: "chart.xyaxis.line"
            case .session: "timer"
            case .notifications: "bell.badge.fill"
            case .advanced: "terminal.fill"
            }
        }

        /// Tile gradient, top to bottom: the pacing colors where they fit, quiet graphite elsewhere.
        var tile: (UInt32, UInt32) {
            switch self {
            case .general: (0x9A9CA5, 0x5F626B)
            case .menuBar: (0x64A8FF, 0x2270F0)
            case .card: (0x9B95FF, 0x5B52E6)
            case .session: (0xFFCB55, 0xE99200)
            case .notifications: (0xFF6F86, 0xDD2448)
            case .advanced: (0x6E7480, 0x33373F)
            }
        }

        var copy: (title: String, body: String) {
            switch self {
            case .general: ("The essentials.", "Which tools Headroom watches, how it looks, and how it starts.")
            case .menuBar: ("Shape your menu bar.", "Five cells per tool: blue means room to spare, white means on pace, amber and rose mean slow down.")
            case .card: ("Your Pace card.", "Meters and graphs for the week and for the 5-hour session. Keep what you read, hide what you don't.")
            case .session: ("Never get cut off\nmid-session.", "Pick when the session starts warning. From there it turns amber, counts down in the menu bar and can let you know.")
            case .notifications: ("Only what's worth a ping.", "Each alert fires once per session or week. Headroom never repeats itself.")
            case .advanced: ("Fine-tuning.", "Plan prices for the cost comparison, the command-line tool, and where to find the CLIs.")
            }
        }
    }

    enum Action: Hashable {
        case section(Section)
        case welcome
        case provider(Provider)
        case appearance(AppAppearance)
        case login, statusChecks, costOnShares
        case menuMode(MenuBarMode)
        case focus(MeterFocus)
        case percent, timer
        case part(CardPart)
        case detail(SessionDetail)
        case warnAt(Double)
        case notify(NotificationKind)
        case notifyLimit
        case openNotificationSettings
        case installCLI
        case choose(String)
        case revealPricing
    }

    private let settings: AppSettings
    private weak var model: AppModel?
    var openWelcome: (() -> Void)?
    private(set) var section: Section = .general
    private var notifyStatus = ""
    private var cliStatus = ""
    private var cliMessage: String?
    private var priceFields: [Provider: NSTextField] = [:]
    private var pathFields: [String: NSTextField] = [:]

    init(settings: AppSettings, model: AppModel?) {
        self.settings = settings
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        for p in Provider.allCases { priceFields[p] = makeField() }
        for tool in ["claude", "codex"] { pathFields[tool] = makeField() }
        syncFields()
        placeFields()
        refreshStatuses()
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ s: Section, animated: Bool = true) {
        guard s != section else { return }
        window?.makeFirstResponder(self)
        if animated { crossfade() }
        section = s
        hovered = nil
        placeFields()
        needsDisplay = true
    }

    /// Offscreen rendering for the README images and the visual pass.
    func render(section s: Section, ctx: CGContext) {
        section = s
        drawContent(ctx)
    }

    // MARK: Input

    override func handle(_ action: AnyHashable) {
        guard let a = action.base as? Action else { return }
        if case .section = a {} else { window?.makeFirstResponder(self) }
        let s = settings
        switch a {
        case .section(let sec): select(sec)
        case .welcome: openWelcome?()
        case .provider(let p):
            var set = s.enabledProviders
            if set.contains(p) {
                // Keep at least one: an empty menu bar item helps no one.
                guard set.count > 1 else { NSSound.beep(); return }
                set.remove(p)
            } else {
                set.insert(p)
            }
            s.enabledProviders = set
            if !set.contains(.claude), s.menuBarMode == .claude { s.menuBarMode = .both }
            if !set.contains(.codex), s.menuBarMode == .codex { s.menuBarMode = .both }
        case .appearance(let ap): s.appearance = ap
        case .login:
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            } catch { NSSound.beep() }
        case .statusChecks: s.statusChecks.toggle()
        case .costOnShares: s.costOnShares.toggle()
        case .menuMode(let m): s.menuBarMode = m
        case .focus(let f): s.meterFocus = f
        case .percent: s.showPercentInMenuBar.toggle()
        case .timer: s.alwaysShowSessionTimer.toggle()
        case .part(let part): s.setShows(part, !s.shows(part))
        case .detail(let d): s.sessionDetail = d
        case .warnAt(let v): s.sessionWarnAt = v
        case .notify(let kind):
            let on = !s.notifies(kind)
            s.setNotifies(kind, on)
            if on { Notifier.requestAuthorization { [weak self] _ in self?.refreshStatuses() } }
        case .notifyLimit:
            let on = !s.notifies(.sessionWarning)
            s.setNotifies(.sessionWarning, on)
            s.setNotifies(.sessionLimit, on)
            if on { Notifier.requestAuthorization { [weak self] _ in self?.refreshStatuses() } }
        case .openNotificationSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        case .installCLI:
            cliMessage = CLIInstaller.install()
            refreshStatuses()
        case .choose(let tool): choose(tool)
        case .revealPricing: revealPricing()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let all = Section.allCases
        switch event.keyCode {
        case 125: select(all[min(section.rawValue + 1, all.count - 1)]) // ↓
        case 126: select(all[max(section.rawValue - 1, 0)]) // ↑
        case 13 where event.modifierFlags.contains(.command): window?.performClose(nil) // ⌘W
        default: super.keyDown(with: event)
        }
    }

    // MARK: Statuses

    func refreshStatuses() {
        Task {
            let status = await CLIInstaller.status()
            cliStatus = [cliMessage, status].compactMap { $0 }.joined(separator: " ")
            needsDisplay = true
        }
        guard Notifier.available else {
            notifyStatus = "Alerts need Headroom.app; this build runs on its own."
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            Task { @MainActor in
                self.notifyStatus = switch status {
                case .denied: "Notifications are off for Headroom in System Settings."
                case .notDetermined: "macOS asks for permission the first time you turn one on."
                default: "Allowed in System Settings."
                }
                self.needsDisplay = true
            }
        }
    }

    // MARK: Text fields (Advanced)

    private func makeField() -> NSTextField {
        let f = NSTextField(string: "")
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = F.sf(12.5, 500, tabular: true)
        f.textColor = .labelColor
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.lineBreakMode = .byTruncatingHead
        f.delegate = self
        addSubview(f)
        return f
    }

    private func setPlaceholder(_ f: NSTextField, _ text: String) {
        f.placeholderAttributedString = NSAttributedString(string: text, attributes: [.font: F.sf(12.5, 500, tabular: true), .foregroundColor: NSColor.tertiaryLabelColor])
    }

    /// Reads the stored values back into the fields not being edited.
    func syncFields() {
        for (p, f) in priceFields where !isEditing(f) {
            f.stringValue = settings.planPriceOverride(p).map { String(format: "%.0f", $0) } ?? ""
            setPlaceholder(f, listPrice(p).flatMap { $0 > 0 ? "\(Int($0)) list" : nil } ?? "list price")
        }
        for (tool, f) in pathFields where !isEditing(f) {
            f.stringValue = settings.cliPath(tool).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            setPlaceholder(f, "Found automatically")
        }
    }

    private func isEditing(_ f: NSTextField) -> Bool {
        (window?.firstResponder as? NSTextView)?.delegate === f
    }

    private func placeFields() {
        let show = section == .advanced
        let l = advancedLayout()
        for (p, f) in priceFields {
            f.isHidden = !show
            if let r = l.price[p] { f.frame = fieldTextFrame(r, prefix: true) }
        }
        for (tool, f) in pathFields {
            f.isHidden = !show
            if let r = l.path[tool] { f.frame = fieldTextFrame(r) }
        }
    }

    private func fieldTextFrame(_ r: CGRect, prefix: Bool = false) -> CGRect {
        let inset: CGFloat = prefix ? 22 : 10
        return CGRect(x: r.minX + inset, y: r.midY - 8.5, width: r.width - inset - 10, height: 17)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let (p, _) = priceFields.first(where: { $0.value === field }) {
            let text = field.stringValue.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
            settings.setPlanPriceOverride(text.isEmpty ? nil : Double(text), for: p)
        }
        if let (tool, _) = pathFields.first(where: { $0.value === field }) {
            let path = field.stringValue.trimmingCharacters(in: .whitespaces)
            settings.setCLIPath(path.isEmpty ? nil : (path as NSString).expandingTildeInPath, for: tool)
        }
        syncFields()
        needsDisplay = true
    }

    private func choose(_ tool: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(tool) executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCLIPath(url.path, for: tool)
        syncFields()
    }

    private func revealPricing() {
        let url = PriceTable.defaultOverrideURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = #"{"as_of": "2026-10-18", "models": {}, "aliases": {}}"# + "\n"
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func listPrice(_ p: Provider) -> Double? {
        model?.faults[p]?.lastGood?.plan?.monthlyPriceUSD
    }

    // MARK: Layout

    private var contentX: CGFloat { Self.sidebarWidth + 36 }
    private var stageRect: CGRect { CGRect(x: bounds.maxX - 12 - Self.stageWidth, y: 12, width: Self.stageWidth, height: bounds.height - 24) }
    private var contentWidth: CGFloat { stageRect.minX - 36 - contentX }

    private func titleBlock(_ s: Section) -> TextBlock {
        TextBlock(s.copy.title, F.sf(27, 700), theme.ink, width: contentWidth, lineHeight: 32, kern: -0.6)
    }

    private func bodyBlock(_ s: Section) -> TextBlock {
        TextBlock(s.copy.body, F.sf(13.5, 400), theme.muted, width: contentWidth, lineHeight: 19.5)
    }

    /// Where a section's controls begin, under its eyebrow, title and body.
    private func controlsTop(_ s: Section) -> CGFloat {
        52 + 22 + titleBlock(s).height + 10 + bodyBlock(s).height + 26
    }

    private struct AdvancedLayout {
        var price: [Provider: CGRect] = [:]
        var priceRows: [Provider: CGFloat] = [:]
        var cliLabel: CGFloat = 0
        var cliRow: CGFloat = 0
        var pathLabel: CGFloat = 0
        var path: [String: CGRect] = [:]
        var pathRows: [String: CGFloat] = [:]
        var footer: CGFloat = 0
    }

    private func advancedLayout() -> AdvancedLayout {
        var l = AdvancedLayout()
        let x = contentX, w = contentWidth
        var y = controlsTop(.advanced)
        y += 14
        for p in Provider.allCases {
            l.priceRows[p] = y
            l.price[p] = CGRect(x: x + w - 104, y: y + 4, width: 104, height: 30)
            y += 40
        }
        y += 14
        l.cliLabel = y
        y += 14
        l.cliRow = y
        y += 52 + 12
        l.pathLabel = y
        y += 14
        for tool in ["claude", "codex"] {
            l.pathRows[tool] = y
            l.path[tool] = CGRect(x: x + 62, y: y + 4, width: w - 62 - 92, height: 30)
            y += 40
        }
        l.footer = y + 14
        return l
    }

    // MARK: Drawing

    override func drawContent(_ ctx: CGContext) {
        let t = theme
        let b = bounds
        ctx.fill(CGPath(rect: b, transform: nil), t.isDark ? rgb(0x15161A) : rgb(0xF2F2F5))
        ctx.fillRadial(in: CGPath(rect: b, transform: nil), center: CGPoint(x: stageRect.minX, y: b.minY), radii: CGSize(width: 420, height: 260),
                       color: t.isDark ? white(0.03) : white(0.85), fadeAt: 0.8)
        drawSidebar(ctx)
        SettingsStage.draw(section, rect: stageRect, settings: settings, model: model, theme: t, ctx: ctx)

        let x0 = contentX, w = contentWidth
        var y: CGFloat = 52
        Text("SETTINGS · \(section.title.uppercased())", F.mono(10, 600), t.muted, kern: 1.1).draw(x: x0, capCenter: y, in: ctx)
        y += 22
        let title = titleBlock(section)
        title.draw(x: x0, top: y, in: ctx)
        y += title.height + 10
        bodyBlock(section).draw(x: x0, top: y, in: ctx)
        y = controlsTop(section)

        switch section {
        case .general: drawGeneral(x: x0, y: y, w: w, ctx: ctx)
        case .menuBar: drawMenuBar(x: x0, y: y, w: w, ctx: ctx)
        case .card: drawCard(x: x0, y: y, w: w, ctx: ctx)
        case .session: drawSession(x: x0, y: y, w: w, ctx: ctx)
        case .notifications: drawNotifications(x: x0, y: y, w: w, ctx: ctx)
        case .advanced: drawAdvanced(x: x0, w: w, ctx: ctx)
        }
    }

    private func drawSidebar(_ ctx: CGContext) {
        let t = theme
        let side = CGRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height)
        ctx.fill(CGPath(rect: side, transform: nil), t.isDark ? black(0.18) : black(0.025))
        ctx.fill(CGPath(rect: CGRect(x: side.maxX - 0.5, y: 0, width: 0.5, height: side.height), transform: nil), t.isDark ? white(0.07) : black(0.07))

        HeadroomMark.draw(in: CGRect(x: 20, y: 50, width: 32, height: 32), ctx: ctx, dropShadow: false)
        Text("Headroom", F.sf(15, 700), t.ink, kern: -0.2).draw(x: 62, capCenter: 59, in: ctx)
        Text("Settings", F.sf(12, 500), t.muted).draw(x: 62, capCenter: 75, in: ctx)

        var y: CGFloat = 108
        for s in Section.allCases {
            let r = CGRect(x: 10, y: y, width: side.width - 20, height: 36)
            navRow(s.title, symbol: s.symbol, tile: s.tile, selected: s == section, rect: r, action: Action.section(s), ctx: ctx)
            y += 38
        }

        let tour = CGRect(x: 10, y: bounds.height - 88, width: side.width - 20, height: 36)
        navRow("Welcome Tour", symbol: "sparkles", tile: nil, selected: false, rect: tour, action: Action.welcome, ctx: ctx)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        Text(version.map { "Version \($0)" } ?? "Development build", F.sf(10.5, 500, tabular: true), t.muted2)
            .draw(x: 22, capCenter: bounds.height - 30, in: ctx)
    }

    private func navRow(_ title: String, symbol: String, tile: (UInt32, UInt32)?, selected: Bool, rect r: CGRect, action: Action, ctx: CGContext) {
        let t = theme
        let shape = rounded(r, 10)
        if selected {
            ctx.withState {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: (t.isDark ? black(0.35) : black(0.10)).cgColor)
                ctx.fill(shape, t.isDark ? rgb(0x2A2B30) : .white)
            }
            ctx.fillVertical(shape, t.segmentOnTop, t.segmentOnBottom)
            if t.isDark { ctx.innerStroke(shape, white(0.06), width: 0.5) }
        } else if isHovered(action) {
            ctx.fill(shape, t.isDark ? white(0.045) : black(0.04))
        }
        let icon = CGRect(x: r.minX + 8, y: r.midY - 12, width: 24, height: 24)
        let iconShape = rounded(icon, 7)
        if let (top, bottom) = tile {
            ctx.glow(iconShape, color: rgb(bottom, t.isDark ? 0.35 : 0.2), blur: 6, base: rgb(bottom))
            ctx.fillVertical(iconShape, rgb(top), rgb(bottom))
            ctx.withState {
                ctx.addPath(iconShape); ctx.clip()
                ctx.fill(CGPath(rect: CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: 0.75), transform: nil), white(0.35))
            }
            CanvasControlView.drawSymbol(symbol, in: icon.insetBy(dx: 5.5, dy: 5.5), color: .white, ctx: ctx)
        } else {
            ctx.fill(iconShape, t.isDark ? white(0.08) : black(0.06))
            CanvasControlView.drawSymbol(symbol, in: icon.insetBy(dx: 5.5, dy: 5.5), color: t.ink.fade(0.7), ctx: ctx)
        }
        Text(title, F.sf(13, selected ? 650 : 500), selected ? t.ink : t.ink.fade(0.82)).draw(x: icon.maxX + 10, capCenter: r.midY, in: ctx)
        hit(r, action)
    }

    // MARK: Sections

    private func drawGeneral(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        sectionLabel("TOOLS", x: x, y: cy, ctx: ctx)
        cy += 14
        for p in Provider.allCases {
            let on = settings.enabledProviders.contains(p)
            providerCard(p, on: on, status: ProviderStatusLine.text(p, state: ProviderStatusLine.state(p, model: model), enabled: on),
                         rect: CGRect(x: x, y: cy, width: w, height: 62), action: Action.provider(p), ctx: ctx)
            cy += 62 + 10
        }
        cy += 10
        sectionLabel("APPEARANCE", x: x, y: cy, ctx: ctx)
        cy += 14
        let all = AppAppearance.allCases
        segmented(all.map(\.title), selected: all.firstIndex(of: settings.appearance) ?? 0, x: x, y: cy, w: w,
                  actions: all.map { AnyHashable(Action.appearance($0)) }, ctx: ctx)
        cy += 30 + 20
        toggleRow("Open at login", "Headroom starts quietly with your Mac.", on: SMAppService.mainApp.status == .enabled,
                  action: Action.login, x: x, y: cy, w: w, ctx: ctx)
        cy += 48
        toggleRow("Watch service status", "Flags outages from Anthropic and OpenAI.", on: settings.statusChecks,
                  action: Action.statusChecks, x: x, y: cy, w: w, ctx: ctx)
        cy += 48
        toggleRow("Cost on share cards", "Shared images show this week at API rates.", on: settings.costOnShares,
                  action: Action.costOnShares, x: x, y: cy, w: w, ctx: ctx)
    }

    private func drawMenuBar(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        let enabled = settings.enabledProviders
        if enabled.count > 1 {
            sectionLabel("SHOW", x: x, y: cy, ctx: ctx)
            cy += 14
            let modes = MenuBarMode.allCases
            segmented(modes.map(\.title), selected: modes.firstIndex(of: settings.menuBarMode) ?? 0, x: x, y: cy, w: w,
                      actions: modes.map { AnyHashable(Action.menuMode($0)) }, ctx: ctx)
            cy += 30 + 20
        }
        sectionLabel("THE METER TRACKS", x: x, y: cy, ctx: ctx)
        cy += 14
        let focuses = MeterFocus.allCases
        segmented(["This week", "5-hour session", "Tighter"], selected: focuses.firstIndex(of: settings.meterFocus) ?? 0, x: x, y: cy, w: w,
                  actions: focuses.map { AnyHashable(Action.focus($0)) }, ctx: ctx)
        cy += 30 + 20
        toggleRow("Show the percentage", "82% beside each meter.", on: settings.showPercentInMenuBar, action: Action.percent, x: x, y: cy, w: w, ctx: ctx)
        cy += 48
        toggleRow("Always show the 5-hour timer", "Otherwise it appears once the session is nearly used.", on: settings.alwaysShowSessionTimer,
                  action: Action.timer, x: x, y: cy, w: w, ctx: ctx)
        cy += 48 + 14
        if enabled.count > 1 {
            hint(symbol: "rectangle.split.3x1", "Both tools take about 150 pt. Next to the notch macOS hides items that don't fit; Most urgent shows only the tool that needs you.",
                 x: x, y: cy, w: w, ctx: ctx)
        }
    }

    private func drawCard(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        sectionLabel("THIS WEEK", x: x, y: cy, ctx: ctx)
        cy += 14
        toggleRow("Meter", "Five cells for what's left, with even pace marked.", on: settings.shows(.weekMeter),
                  action: Action.part(.weekMeter), x: x, y: cy, w: w, ctx: ctx)
        cy += 48
        toggleRow("Graph", "The week so far, and where your pace takes it.", on: settings.shows(.weekGraph),
                  action: Action.part(.weekGraph), x: x, y: cy, w: w, ctx: ctx)
        cy += 48 + 14
        sectionLabel("5-HOUR SESSION", x: x, y: cy, ctx: ctx)
        cy += 14
        let detailed = settings.sessionDetail == .detailed
        segmented(["Its own panel", "A single row"], selected: detailed ? 0 : 1, x: x, y: cy, w: w,
                  actions: [AnyHashable(Action.detail(.detailed)), AnyHashable(Action.detail(.compact))], ctx: ctx)
        cy += 30 + 14
        toggleRow("Meter", "Five cells for what's left of the session.", on: settings.shows(.sessionMeter),
                  action: Action.part(.sessionMeter), x: x, y: cy, w: w, enabled: detailed, ctx: ctx)
        cy += 48
        toggleRow("Graph", "The five hours so far, and where they're heading.", on: settings.shows(.sessionGraph),
                  action: Action.part(.sessionGraph), x: x, y: cy, w: w, enabled: detailed, ctx: ctx)
        cy += 48
        if !detailed {
            Text("The row turns into a banner once the session warns.", F.sf(12, 500), theme.muted2).draw(x: x, capCenter: cy + 6, in: ctx)
        }
    }

    private func drawSession(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        sectionLabel("WARN ME AT", x: x, y: cy, ctx: ctx)
        cy += 14
        let choices = AppSettings.sessionWarnChoices
        let current = choices.min { abs($0 - settings.sessionWarnAt) < abs($1 - settings.sessionWarnAt) } ?? 0.75
        segmented(choices.map { "\(Int(($0 * 100).rounded()))% used" }, selected: choices.firstIndex(of: current) ?? 2, x: x, y: cy, w: w,
                  actions: choices.map { AnyHashable(Action.warnAt($0)) }, ctx: ctx)
        cy += 30 + 8
        let policy = settings.policy
        Text("Amber from \(Int((policy.sessionAmber * 100).rounded()))%, rose from \(Int((policy.sessionRose * 100).rounded()))%.", F.sf(12, 500), theme.muted2)
            .draw(x: x + 1, capCenter: cy + 6, in: ctx)
        cy += 30
        toggleRow("Notify me near the limit", "At your warning level, and when you hit it.", on: settings.notifies(.sessionWarning),
                  action: Action.notifyLimit, x: x, y: cy, w: w, ctx: ctx)
        cy += 48
        toggleRow("Notify me when it's back", "The moment a used-up session resets.", on: settings.notifies(.sessionReset),
                  action: Action.notify(.sessionReset), x: x, y: cy, w: w, ctx: ctx)
        cy += 48 + 14
        hint(symbol: "terminal", "In Terminal, headroom shows the session forecast, and headroom wait waits for a used-up session to come back.",
             x: x, y: cy, w: w, ctx: ctx)
    }

    private func drawNotifications(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        let details: [NotificationKind: String] = [
            .sessionWarning: "When the session reaches your warning level.",
            .sessionLimit: "When it's used up, with the time it's back.",
            .sessionReset: "The moment a used-up session resets.",
            .weeklyTight: "When the week turns amber or rose.",
            .creditsExpiring: "Two days before a Codex reset credit lapses.",
        ]
        for kind in NotificationKind.allCases {
            toggleRow(kind.title, details[kind] ?? "", on: settings.notifies(kind), action: Action.notify(kind), x: x, y: cy, w: w, ctx: ctx)
            cy += 48
        }
        cy += 12
        let denied = notifyStatus.contains("off for Headroom")
        drawStatusDot(center: CGPoint(x: x + 4, y: cy + 17), color: denied ? theme.amber : theme.muted2, ctx: ctx)
        let btn = button("Notification Settings…", right: x + w, mid: cy + 17, style: .tinted, height: 28, action: Action.openNotificationSettings, ctx: ctx)
        let status = TextBlock(notifyStatus, F.sf(12, 500), theme.muted, width: btn.minX - 16 - x - 14, lineHeight: 15)
        status.draw(x: x + 14, top: cy + 17 - status.height / 2, in: ctx)
    }

    private func drawAdvanced(x: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        let l = advancedLayout()
        sectionLabel("PLAN PRICE · USD A MONTH", x: x, y: l.priceRows[.claude]! - 14, ctx: ctx)
        for p in Provider.allCases {
            guard let row = l.priceRows[p], let field = l.price[p] else { continue }
            BrandMark.drawTile(p, in: CGRect(x: x, y: field.midY - 12, width: 24, height: 24), ctx: ctx, shadow: false)
            Text(p.displayName, F.sf(13, 600), t.ink).draw(x: x + 34, capCenter: row + 12 + 2, in: ctx)
            Text("Sets “× plan” beside the cost", F.sf(11.5), t.muted).draw(x: x + 34, capCenter: row + 28 + 2, in: ctx)
            drawField(field, editing: priceFields[p].map(isEditing) ?? false, prefix: "$", ctx: ctx)
        }

        sectionLabel("COMMAND LINE", x: x, y: l.cliLabel, ctx: ctx)
        let row = CGRect(x: x, y: l.cliRow, width: w, height: 52)
        let panel = rounded(row, 12)
        ctx.fill(panel, t.groupFill)
        ctx.innerStroke(panel, t.groupBorder, width: 0.5)
        let installed = cliStatus.hasPrefix("Installed") || cliStatus.contains("Installed ~/")
        let btn = button(installed ? "Reinstall" : "Install", right: row.maxX - 10, mid: row.midY, style: .tinted, enabled: CLIInstaller.bundledCLI != nil,
                         height: 28, action: Action.installCLI, ctx: ctx)
        Text("headroom", F.mono(12.5, 600), t.ink).draw(x: row.minX + 12, capCenter: row.minY + 17, in: ctx)
        let offPath = cliStatus.contains("isn't on your PATH")
        let status = cliStatus.isEmpty ? "Checking…"
            : offPath ? "Add ~/.local/bin to your PATH in ~/.zshrc."
            : installed ? "In ~/.local/bin, with its man page." : "Your week in Terminal, prompts and tmux."
        Text(status, F.sf(11.5), offPath ? t.amber : t.muted).draw(x: row.minX + 12, capCenter: row.minY + 35, in: ctx)
        _ = btn

        sectionLabel("CLI LOCATIONS", x: x, y: l.pathLabel, ctx: ctx)
        for tool in ["claude", "codex"] {
            guard let field = l.path[tool] else { continue }
            Text(tool, F.mono(12.5, 600), t.ink).draw(x: x, capCenter: field.midY, in: ctx)
            drawField(field, editing: pathFields[tool].map(isEditing) ?? false, prefix: nil, ctx: ctx)
            button("Choose…", right: x + w, mid: field.midY, style: .tinted, height: 28, action: Action.choose(tool), ctx: ctx)
        }

        let pricing = model?.pricingEngine.asOf
        Text(pricing.map { "API rates as of \($0)." } ?? "API rates bundled with this version.", F.sf(12, 500), t.muted)
            .draw(x: x, capCenter: l.footer + 6, in: ctx)
        button("Edit prices…", right: x + w, mid: l.footer + 6, style: .plain, height: 26, action: Action.revealPricing, ctx: ctx)
    }

    private func drawField(_ r: CGRect, editing: Bool, prefix: String?, ctx: CGContext) {
        let t = theme
        let shape = rounded(r, 9)
        ctx.fill(shape, t.isDark ? black(0.25) : .white)
        if editing {
            ctx.withState {
                ctx.setShadow(offset: .zero, blur: 6, color: t.pacing(.plenty).glow.cgColor)
                ctx.stroke(shape, t.pacing(.plenty).bottom, width: 1.5)
            }
        } else {
            ctx.innerStroke(shape, t.isDark ? white(0.10) : black(0.10), width: 0.75)
        }
        if let prefix { Text(prefix, F.sf(12.5, 500), t.muted2).draw(x: r.minX + 10, capCenter: r.midY, in: ctx) }
    }

    /// A quiet panel with an icon and a sentence; `headroom` words are set in mono.
    private func hint(symbol: String, _ text: String, x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        let block = TextBlock(text, F.sf(12, 450), t.muted, width: w - 50, lineHeight: 16)
        let r = CGRect(x: x, y: y, width: w, height: block.height + 22)
        let shape = rounded(r, 12)
        ctx.fill(shape, t.groupFill)
        ctx.innerStroke(shape, t.groupBorder, width: 0.5)
        CanvasControlView.drawSymbol(symbol, in: CGRect(x: r.minX + 13, y: r.minY + 12, width: 16, height: 14), color: t.muted2, weight: .medium, ctx: ctx)
        block.draw(x: r.minX + 38, top: r.minY + 11, in: ctx)
    }
}

/// Installs `headroom` into `~/.local/bin` (symlink into the app) and its man page.
@MainActor
enum CLIInstaller {
    static var binDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin") }
    static var manDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/man/man1") }

    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/headroom")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func install() -> String {
        guard let cli = bundledCLI else { return "This build has no bundled CLI (run from Headroom.app)." }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            let link = binDir.appendingPathComponent("headroom")
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: cli)
            if let man = Bundle.main.url(forResource: "headroom", withExtension: "1") {
                try fm.createDirectory(at: manDir, withIntermediateDirectories: true)
                let dest = manDir.appendingPathComponent("headroom.1")
                if fm.fileExists(atPath: dest.path) || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil { try fm.removeItem(at: dest) }
                try fm.createSymbolicLink(at: dest, withDestinationURL: man)
            }
            return "Installed ~/.local/bin/headroom and headroom(1)."
        } catch {
            return "Couldn't install: \(error.localizedDescription)"
        }
    }

    /// Install state plus a PATH hint (read from the login shell, like the CLI resolver).
    static func status() async -> String {
        let link = binDir.appendingPathComponent("headroom")
        let installed = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        let path = await loginShellPATH()
        let onPath = path.map { $0.split(separator: ":").contains { ($0 as NSString).expandingTildeInPath == binDir.path } } ?? true
        var parts: [String] = [installed ? "Installed at ~/.local/bin/headroom." : "Not installed."]
        if !onPath { parts.append("~/.local/bin isn't on your PATH. Add it in ~/.zshrc: export PATH=\"$HOME/.local/bin:$PATH\"") }
        return parts.joined(separator: " ")
    }

    private static func loginShellPATH() async -> String? {
        let result = try? await SystemProcessRunner().run("/bin/zsh", arguments: ["-lc", "printf %s \"$PATH\""], currentDirectory: nil, timeout: 5)
        guard let r = result, r.status == 0 else { return nil }
        return String(decoding: r.stdout, as: UTF8.self)
    }
}
