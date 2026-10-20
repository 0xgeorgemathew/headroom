import AppKit
import HeadroomCore
import HeadroomKit
import ServiceManagement

/// The welcome window: five short steps that set Headroom up the way the user wants it.
/// Every choice applies the moment it's made, so the menu bar changes behind the window.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings
    private let model: AppModel
    private let view: OnboardingView
    /// Called once the user finishes (true) or closes the window (false).
    var onFinish: ((_ completed: Bool) -> Void)?

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
        view = OnboardingView(settings: settings) { [weak model] p in
            guard let model else { return nil }
            if let r = model.faults[p]?.lastGood { return .signedIn(plan: r.plan?.pill) }
            return model.faults[p]?.fault.map { .fault($0) }
        }
        let window = OnboardingWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Headroom"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.appearance = settings.appearance.nsAppearance
        // A plain container: the drawn view is layer-backed and sets its own contents (see PopoverController).
        let container = NSView(frame: NSRect(origin: .zero, size: OnboardingView.size))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        view.finish = { [weak self] in self?.complete() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(step: Int = 0) {
        view.go(to: step, animated: false)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }

    /// Model changed (a reading arrived): provider statuses may have changed.
    func refresh() {
        if window?.appearance != settings.appearance.nsAppearance { window?.appearance = settings.appearance.nsAppearance }
        view.needsDisplay = true
    }

    private var finished = false

    private func complete() {
        finished = true
        settings.onboardingCompleted = true
        close()
        onFinish?(true)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        // Closing early still counts: the defaults are sensible, and Settings has everything.
        settings.onboardingCompleted = true
        onFinish?(false)
    }
}

final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - The drawn view

@MainActor
final class OnboardingView: NSView {
    static let size = NSSize(width: 800, height: 580)
    static let stageWidth: CGFloat = 340
    static let steps = ["Welcome", "Providers", "Menu bar", "5-hour sessions", "Ready"]

    enum Action: Equatable {
        case next, back, finish
        case provider(Provider)
        case menuMode(MenuBarMode)
        case focus(MeterFocus)
        case percent, timer
        case warnAt(Double)
        case detail(SessionDetail)
        case notifyLimit, notifyReset, notifyWeek
        case login, cli
        case appearance(AppAppearance)
    }

    /// What Headroom knows about a provider so far (nil: nothing yet).
    enum ProviderState { case signedIn(plan: String?), fault(Fault) }

    private let settings: AppSettings
    private let providerState: (Provider) -> ProviderState?
    var finish: (() -> Void)?
    private(set) var step = 0
    private var regions: [(rect: CGRect, action: Action)] = []
    private var hovered: Action?
    private var installCLI = true
    private var launchAtLogin = true
    private var fade: (image: CGImage, start: Date)?
    private var fadeTimer: Timer?

    init(settings: AppSettings, providerState: @escaping (Provider) -> ProviderState?) {
        self.settings = settings
        self.providerState = providerState
        launchAtLogin = SMAppService.mainApp.status == .enabled || !settings.onboardingCompleted
        installCLI = CLIInstaller.bundledCLI != nil
        super.init(frame: NSRect(origin: .zero, size: Self.size))
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

    func go(to s: Int, animated: Bool = true) {
        let target = min(max(s, 0), Self.steps.count - 1)
        guard target != step || !animated else { return }
        if animated, window != nil, let image = CPUCanvas.image(for: self, { self.drawContent($0) }) { beginFade(image) }
        step = target
        hovered = nil
        needsDisplay = true
    }

    private func beginFade(_ image: CGImage) {
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

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = regions.last { $0.rect.contains(p) }?.action
        if h != hovered { hovered = h; needsDisplay = true }
        if h != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let action = regions.last(where: { $0.rect.contains(p) })?.action else {
            window?.performDrag(with: event)
            return
        }
        perform(action)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: perform(step == Self.steps.count - 1 ? .finish : .next) // return, enter
        case 123: if step > 0 { perform(.back) } // ←
        case 124: if step < Self.steps.count - 1 { perform(.next) } // →
        default: super.keyDown(with: event)
        }
    }

    private func perform(_ a: Action) {
        switch a {
        case .next:
            guard canContinue else { NSSound.beep(); return }
            if step == 3, anyNotifications { Notifier.requestAuthorization() }
            go(to: step + 1)
        case .back: go(to: step - 1)
        case .finish: finishSetup()
        case .provider(let p):
            var set = settings.enabledProviders
            if set.contains(p) { set.remove(p) } else { set.insert(p) }
            settings.enabledProviders = set
            if !set.contains(.claude), settings.menuBarMode == .claude { settings.menuBarMode = .both }
            if !set.contains(.codex), settings.menuBarMode == .codex { settings.menuBarMode = .both }
        case .menuMode(let m): settings.menuBarMode = m
        case .focus(let f): settings.meterFocus = f
        case .percent: settings.showPercentInMenuBar.toggle()
        case .timer: settings.alwaysShowSessionTimer.toggle()
        case .warnAt(let v): settings.sessionWarnAt = v
        case .detail(let d): settings.sessionDetail = d
        case .notifyLimit:
            let on = !settings.notifies(.sessionWarning)
            settings.setNotifies(.sessionWarning, on)
            settings.setNotifies(.sessionLimit, on)
        case .notifyReset: settings.setNotifies(.sessionReset, !settings.notifies(.sessionReset))
        case .notifyWeek: settings.setNotifies(.weeklyTight, !settings.notifies(.weeklyTight))
        case .login: launchAtLogin.toggle()
        case .cli: installCLI.toggle()
        case .appearance(let a): settings.appearance = a
        }
        needsDisplay = true
    }

    private var canContinue: Bool { step != 1 || !settings.enabledProviders.isEmpty }
    private var anyNotifications: Bool { [.sessionWarning, .sessionReset, .weeklyTight].contains { settings.notifies($0) } }

    private func finishSetup() {
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        if installCLI, CLIInstaller.bundledCLI != nil { _ = CLIInstaller.install() }
        if anyNotifications { Notifier.requestAuthorization() }
        finish?()
    }

    /// Offscreen rendering for the README images.
    func render(step: Int, ctx: CGContext) {
        self.step = step
        drawContent(ctx)
    }

    // MARK: Drawing

    private func drawContent(_ ctx: CGContext) {
        regions.removeAll()
        let t = theme
        let b = bounds
        // Window surface.
        ctx.fill(CGPath(rect: b, transform: nil), t.isDark ? rgb(0x15161A) : rgb(0xF2F2F5))
        ctx.fillRadial(in: CGPath(rect: b, transform: nil), center: CGPoint(x: b.maxX, y: b.minY), radii: CGSize(width: 520, height: 300),
                       color: t.isDark ? white(0.035) : white(0.9), fadeAt: 0.8)
        let stage = CGRect(x: 12, y: 12, width: Self.stageWidth, height: b.height - 24)
        OnboardingStage.draw(step: step, rect: stage, settings: settings, theme: t, ctx: ctx)

        let x0 = stage.maxX + 44, w = b.maxX - 44 - x0
        var y: CGFloat = 52
        // Eyebrow.
        Text("STEP \(step + 1) OF \(Self.steps.count) · \(Self.steps[step].uppercased())", F.mono(10, 600), t.muted, kern: 1.1)
            .draw(x: x0, capCenter: y, in: ctx)
        y += 22
        let (title, body) = copy(step)
        let titleBlock = TextBlock(title, F.sf(27, 700), t.ink, width: w, lineHeight: 32, kern: -0.6)
        titleBlock.draw(x: x0, top: y, in: ctx)
        y += titleBlock.height + 10
        let bodyBlock = TextBlock(body, F.sf(13.5, 400), t.muted, width: w, lineHeight: 19.5)
        bodyBlock.draw(x: x0, top: y, in: ctx)
        y += bodyBlock.height + 24

        switch step {
        case 0: drawWelcome(x: x0, y: y, w: w, ctx: ctx)
        case 1: drawProviders(x: x0, y: y, w: w, ctx: ctx)
        case 2: drawMenuBarOptions(x: x0, y: y, w: w, ctx: ctx)
        case 3: drawSessionOptions(x: x0, y: y, w: w, ctx: ctx)
        default: drawReady(x: x0, y: y, w: w, ctx: ctx)
        }
        drawNavigation(x: x0, w: w, bottom: b.maxY - 34, ctx: ctx)
    }

    private func copy(_ step: Int) -> (String, String) {
        switch step {
        case 0: ("Room to spare,\nat a glance.", "Headroom compares what's left of your Claude and Codex allowance with the time left until it renews, and tells you whether to use more, keep going, or ease off.")
        case 1: ("What do you use?", "Pick the tools to keep an eye on. Headroom reads limits from the apps you're already signed in to. Nothing is sent anywhere.")
        case 2: ("Shape your menu bar.", "Five cells per tool: blue means room to spare, white means on pace, amber and rose mean slow down. The preview on the left updates as you choose.")
        case 3: ("Never get cut off\nmid-session.", "The 5-hour session is the limit you hit first. Headroom forecasts it, warns you in time, and tells you when it's back.")
        default: ("You're all set.", "Headroom lives in your menu bar. Click it for the full picture, or right-click any card to share it. Everything here is in Settings too.")
        }
    }

    // MARK: Steps

    private func drawWelcome(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        let items: [(PacingState, String, String)] = [
            (.plenty, "Plenty available", "Use more. It renews before you'd run out."),
            (.onPace, "On pace", "Keep going. It lasts to the renewal."),
            (.tight, "Getting tight", "Ease off a little to make it."),
            (.veryTight, "Very tight", "Slow down, or it runs out early."),
        ]
        var cy = y
        for (state, name, line) in items {
            let c = t.pacing(state)
            let cell = rounded(CGRect(x: x, y: cy + 3, width: 26, height: 14), 4.5)
            ctx.glow(cell, color: c.glow, blur: 8, base: c.bottom)
            ctx.fillVertical(cell, c.top, c.bottom)
            Text(name, F.sf(13, 650), t.ink).draw(x: x + 40, capCenter: cy + 10, in: ctx)
            Text(line, F.sf(12.5), t.muted).draw(x: x + 40, capCenter: cy + 28, in: ctx)
            cy += 48
        }
    }

    private func providerStatus(_ p: Provider) -> (text: String, good: Bool?) {
        switch providerState(p) {
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
            return (settings.enabledProviders.contains(p) ? "Found · reading limits…" : "Found on this Mac", nil)
        }
        return ("Not set up yet · add it any time", nil)
    }

    private func drawProviders(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        var cy = y
        for p in Provider.allCases {
            let on = settings.enabledProviders.contains(p)
            let r = CGRect(x: x, y: cy, width: w, height: 70)
            let hover = hovered == .provider(p)
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
            BrandMark.drawTile(p, in: CGRect(x: r.minX + 16, y: r.midY - 20, width: 40, height: 40), ctx: ctx)
            let name = p == .claude ? "Claude Code" : "Codex"
            Text(name, F.sf(14.5, 650), t.ink, kern: -0.1).draw(x: r.minX + 70, capCenter: r.midY - 9, in: ctx)
            let status = providerStatus(p)
            let sc: NSColor = status.good == true ? t.ok : (status.good == false ? t.amber : t.muted2)
            drawStatusDot(center: CGPoint(x: r.minX + 73, y: r.midY + 11), color: sc, ctx: ctx)
            Text(status.text, F.sf(12, 500), t.muted).draw(x: r.minX + 83, capCenter: r.midY + 11, in: ctx)
            drawCheck(on: on, center: CGPoint(x: r.maxX - 26, y: r.midY), tint: brand.base, ctx: ctx)
            regions.append((r, .provider(p)))
            cy += 70 + 12
        }
        if settings.enabledProviders.isEmpty {
            Text("Choose at least one to continue.", F.sf(12, 500), t.amber).draw(x: x + 2, capCenter: cy + 8, in: ctx)
        }
    }

    private func drawMenuBarOptions(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        let enabled = settings.enabledProviders
        var modes: [MenuBarMode] = [.both, .mostUrgent]
        if enabled.count < 2 { modes = [] }
        if !modes.isEmpty {
            label("SHOW", x: x, y: cy, ctx: ctx)
            cy += 14
            segmented(modes.map(\.title), selected: modes.firstIndex(of: settings.menuBarMode) ?? -1, x: x, y: cy, w: w,
                      actions: modes.map { .menuMode($0) }, ctx: ctx)
            cy += 30 + 18
        }
        label("THE METER TRACKS", x: x, y: cy, ctx: ctx)
        cy += 14
        let focuses = MeterFocus.allCases
        segmented(["This week", "5-hour session", "Tighter"], selected: focuses.firstIndex(of: settings.meterFocus) ?? 0, x: x, y: cy, w: w,
                  actions: focuses.map { .focus($0) }, ctx: ctx)
        cy += 30 + 18
        toggleRow("Show the percentage", "82% beside each meter.", on: settings.showPercentInMenuBar, action: .percent, x: x, y: cy, w: w, ctx: ctx)
        cy += 50
        toggleRow("Always show the 5-hour timer", "Otherwise it appears once the session is nearly used.", on: settings.alwaysShowSessionTimer,
                  action: .timer, x: x, y: cy, w: w, ctx: ctx)
    }

    private func drawSessionOptions(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        label("WARN ME AT", x: x, y: cy, ctx: ctx)
        cy += 14
        let choices = AppSettings.sessionWarnChoices
        let current = choices.min { abs($0 - settings.sessionWarnAt) < abs($1 - settings.sessionWarnAt) } ?? 0.75
        segmented(choices.map { "\(Int(($0 * 100).rounded()))% used" }, selected: choices.firstIndex(of: current) ?? 2, x: x, y: cy, w: w,
                  actions: choices.map { .warnAt($0) }, ctx: ctx)
        cy += 30 + 18
        label("ON EACH CARD", x: x, y: cy, ctx: ctx)
        cy += 14
        segmented(["Detailed with forecast", "Compact"], selected: settings.sessionDetail == .detailed ? 0 : 1, x: x, y: cy, w: w,
                  actions: [.detail(.detailed), .detail(.compact)], ctx: ctx)
        cy += 30 + 18
        toggleRow("Notify me near the limit", "At your warning level, and when you hit it.", on: settings.notifies(.sessionWarning),
                  action: .notifyLimit, x: x, y: cy, w: w, ctx: ctx)
        cy += 47
        toggleRow("Notify me when it's back", "The moment a used-up session resets.", on: settings.notifies(.sessionReset),
                  action: .notifyReset, x: x, y: cy, w: w, ctx: ctx)
        cy += 47
        toggleRow("Notify me when the week gets tight", "When it turns amber or rose.", on: settings.notifies(.weeklyTight),
                  action: .notifyWeek, x: x, y: cy, w: w, ctx: ctx)
    }

    private func drawReady(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        toggleRow("Open at login", "Headroom starts quietly with your Mac.", on: launchAtLogin, action: .login, x: x, y: cy, w: w, ctx: ctx)
        cy += 50
        if CLIInstaller.bundledCLI != nil {
            toggleRow("Add the headroom command", "Your week in Terminal, prompts and tmux.", on: installCLI, action: .cli, x: x, y: cy, w: w, ctx: ctx)
            cy += 50
        }
        cy += 6
        label("APPEARANCE", x: x, y: cy, ctx: ctx)
        cy += 14
        let all = AppAppearance.allCases
        segmented(all.map(\.title), selected: all.firstIndex(of: settings.appearance) ?? 0, x: x, y: cy, w: w,
                  actions: all.map { .appearance($0) }, ctx: ctx)
    }

    private func drawNavigation(x: CGFloat, w: CGFloat, bottom: CGFloat, ctx: CGContext) {
        let t = theme
        let mid = bottom - 17
        // Progress: the meter fills a cell per step, in the meter-H colors.
        for i in 0..<Self.steps.count {
            let r = CGRect(x: x + CGFloat(i) * 17, y: mid - 4, width: 13, height: 8)
            let shape = rounded(r, 3)
            if i <= step {
                // The pearl cell needs ink on a light window to be seen.
                let c = (!t.isDark && i == 2) ? rgb(0x50535B) : rgb(HeadroomMark.cellColors[i])
                ctx.glow(shape, color: c.fade(0.6), blur: 6, base: c)
                ctx.fill(shape, c)
            } else {
                ctx.fill(shape, t.isDark ? white(0.10) : black(0.09))
            }
        }
        let last = step == Self.steps.count - 1
        let primary = last ? "Start using Headroom" : (step == 0 ? "Get started" : "Continue")
        let pr = button(primary, right: x + w, mid: mid, primary: true, enabled: canContinue, action: last ? .finish : .next, ctx: ctx)
        if step > 0 { _ = button("Back", right: pr.minX - 8, mid: mid, primary: false, enabled: true, action: .back, ctx: ctx) }
    }

    // MARK: Controls

    private func label(_ s: String, x: CGFloat, y: CGFloat, ctx: CGContext) {
        Text(s, F.sf(9.5, 700), theme.muted2, kern: 0.9).draw(x: x + 1, capCenter: y + 4, in: ctx)
    }

    private func segmented(_ items: [String], selected: Int, x: CGFloat, y: CGFloat, w: CGFloat, actions: [Action], ctx: CGContext) {
        let t = theme
        let r = CGRect(x: x, y: y, width: w, height: 30)
        let track = rounded(r, 10)
        ctx.fill(track, t.segmentTrack)
        if t.isDark { ctx.innerStroke(track, t.segmentTrackBorder, width: 0.5) }
        let font = F.sf(12, 600)
        // Widths follow the labels, then share out the spare room evenly.
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
            } else if hovered == actions[i] {
                ctx.fill(rounded(seg, 8), t.isDark ? white(0.04) : white(0.5))
            }
            Text(item, font, t.ink.fade(i == selected ? 1 : 0.55)).draw(x: seg.midX, capCenter: seg.midY, align: .center, in: ctx)
            regions.append((seg, actions[i]))
            sx += sw
        }
    }

    private func toggleRow(_ title: String, _ detail: String, on: Bool, action: Action, x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        let r = CGRect(x: x, y: y, width: w, height: 40)
        if hovered == action { ctx.fill(rounded(r.insetBy(dx: -8, dy: -2), 10), t.isDark ? white(0.035) : black(0.025)) }
        Text(title, F.sf(13, 600), t.ink).draw(x: x, capCenter: r.minY + 12, in: ctx)
        Text(detail, F.sf(12), t.muted).draw(x: x, capCenter: r.minY + 30, in: ctx)
        drawSwitch(on: on, rect: CGRect(x: r.maxX - 36, y: r.midY - 11, width: 36, height: 22), ctx: ctx)
        regions.append((r.insetBy(dx: -8, dy: -2), action))
    }

    private func drawSwitch(on: Bool, rect: CGRect, ctx: CGContext) {
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

    private func drawCheck(on: Bool, center c: CGPoint, tint: NSColor, ctx: CGContext) {
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

    private func button(_ title: String, right: CGFloat, mid: CGFloat, primary: Bool, enabled: Bool, action: Action, ctx: CGContext) -> CGRect {
        let t = theme
        let font = F.sf(13, 650)
        let label = Text(title, font, .black)
        let r = CGRect(x: right - label.width - 36, y: mid - 17, width: label.width + 36, height: 34)
        let shape = rounded(r, 11)
        let hover = hovered == action && enabled
        if primary {
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
        } else {
            if hover { ctx.fill(shape, t.isDark ? white(0.07) : black(0.05)) }
            Text(title, font, t.muted).draw(x: r.midX, capCenter: r.midY, align: .center, in: ctx)
        }
        regions.append((r, action))
        return r
    }
}
