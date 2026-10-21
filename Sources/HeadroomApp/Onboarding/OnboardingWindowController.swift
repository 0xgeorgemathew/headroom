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
        view = OnboardingView(settings: settings) { [weak model] p in ProviderStatusLine.state(p, model: model) }
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
final class OnboardingView: CanvasControlView {
    static let size = NSSize(width: 800, height: 580)
    static let stageWidth: CGFloat = 340
    static let steps = ["Welcome", "Providers", "Menu bar", "5-hour sessions", "Ready"]

    enum Action: Hashable {
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

    private let settings: AppSettings
    private let providerState: (Provider) -> ProviderStatusLine.State?
    var finish: (() -> Void)?
    private(set) var step = 0
    private var installCLI = true
    private var launchAtLogin = true

    init(settings: AppSettings, providerState: @escaping (Provider) -> ProviderStatusLine.State?) {
        self.settings = settings
        self.providerState = providerState
        launchAtLogin = SMAppService.mainApp.status == .enabled || !settings.onboardingCompleted
        installCLI = CLIInstaller.bundledCLI != nil
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    func go(to s: Int, animated: Bool = true) {
        let target = min(max(s, 0), Self.steps.count - 1)
        guard target != step || !animated else { return }
        if animated { crossfade() }
        step = target
        hovered = nil
        needsDisplay = true
    }

    // MARK: Input

    override func handle(_ action: AnyHashable) {
        if let a = action.base as? Action { perform(a) }
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

    override func drawContent(_ ctx: CGContext) {
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
        ProviderStatusLine.text(p, state: providerState(p), enabled: settings.enabledProviders.contains(p))
    }

    private func drawProviders(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        let t = theme
        var cy = y
        for p in Provider.allCases {
            providerCard(p, on: settings.enabledProviders.contains(p), status: providerStatus(p),
                         rect: CGRect(x: x, y: cy, width: w, height: 70), action: Action.provider(p), ctx: ctx)
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
        toggleRow("Show the percentage", "82% beside each meter.", on: settings.showPercentInMenuBar, action: Action.percent, x: x, y: cy, w: w, ctx: ctx)
        cy += 50
        toggleRow("Always show the 5-hour timer", "Otherwise it appears once the session is nearly used.", on: settings.alwaysShowSessionTimer,
                  action: Action.timer, x: x, y: cy, w: w, ctx: ctx)
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
                  action: Action.notifyLimit, x: x, y: cy, w: w, ctx: ctx)
        cy += 47
        toggleRow("Notify me when it's back", "The moment a used-up session resets.", on: settings.notifies(.sessionReset),
                  action: Action.notifyReset, x: x, y: cy, w: w, ctx: ctx)
        cy += 47
        toggleRow("Notify me when the week gets tight", "When it turns amber or rose.", on: settings.notifies(.weeklyTight),
                  action: Action.notifyWeek, x: x, y: cy, w: w, ctx: ctx)
    }

    private func drawReady(x: CGFloat, y: CGFloat, w: CGFloat, ctx: CGContext) {
        var cy = y
        toggleRow("Open at login", "Headroom starts quietly with your Mac.", on: launchAtLogin, action: Action.login, x: x, y: cy, w: w, ctx: ctx)
        cy += 50
        if CLIInstaller.bundledCLI != nil {
            toggleRow("Add the headroom command", "Your week in Terminal, prompts and tmux.", on: installCLI, action: Action.cli, x: x, y: cy, w: w, ctx: ctx)
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

    private func label(_ s: String, x: CGFloat, y: CGFloat, ctx: CGContext) { sectionLabel(s, x: x, y: y, ctx: ctx) }

    private func segmented(_ items: [String], selected: Int, x: CGFloat, y: CGFloat, w: CGFloat, actions: [Action], ctx: CGContext) {
        segmented(items, selected: selected, x: x, y: y, w: w, actions: actions.map(AnyHashable.init), ctx: ctx)
    }

    private func button(_ title: String, right: CGFloat, mid: CGFloat, primary: Bool, enabled: Bool, action: Action, ctx: CGContext) -> CGRect {
        button(title, right: right, mid: mid, style: primary ? .primary : .plain, enabled: enabled, action: action, ctx: ctx)
    }
}
