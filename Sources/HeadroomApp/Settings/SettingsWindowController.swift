import AppKit
import HeadroomCore
import HeadroomKit
import ServiceManagement
import UserNotifications

/// Settings: a standard macOS preferences window with one tab per area. Every control writes
/// through to `AppSettings` at once, and re-syncs when something else (the welcome window) changes it.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings: AppSettings
    private let model: AppModel
    var openWelcome: (() -> Void)?
    /// Each control's "read the current value back" closure.
    private var syncers: [() -> Void] = []
    private var targets: [ActionTarget] = []
    private var priceFields: [Provider: NSTextField] = [:]
    private var pathFields: [String: NSTextField] = [:]
    private var cliStatus: NSTextField!
    private var notifyStatus: NSTextField!

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        for (title, symbol, view) in [("General", "gearshape", general()), ("Menu Bar", "menubar.rectangle", menuBar()),
                                       ("5-Hour Session", "timer", session()), ("Notifications", "bell.badge", notifications()),
                                       ("Advanced", "slider.horizontal.3", advanced())] {
            let vc = NSViewController()
            vc.view = view
            vc.title = title
            vc.preferredContentSize = view.fittingSize
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.title = "General"
        window.center()
        refreshCLIStatus()
        refreshNotificationStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Settings or readings changed elsewhere.
    func refresh() {
        for sync in syncers { sync() }
    }

    // MARK: Building blocks

    private func page(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 30, bottom: 24, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 560),
        ])
        return container
    }

    private func header(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func note(_ text: String, width: CGFloat = 500) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
        return l
    }

    private func spacer(_ h: CGFloat = 8) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 10
        r.alignment = .firstBaseline
        return r
    }

    /// A label column so popups line up like System Settings.
    private func labeled(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return row([l, control])
    }

    private func check(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let target = ActionTarget()
        let b = NSButton(checkboxWithTitle: title, target: target, action: #selector(ActionTarget.fire(_:)))
        target.handler = { sender in set((sender as? NSButton)?.state == .on) }
        targets.append(target)
        let sync: () -> Void = { [weak b] in b?.state = get() ? .on : .off }
        sync()
        syncers.append(sync)
        return b
    }

    private func popup<T: Equatable>(_ options: [(String, T)], get: @escaping () -> T, set: @escaping (T) -> Void) -> NSPopUpButton {
        let target = ActionTarget()
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, _) in options { p.addItem(withTitle: title) }
        p.target = target
        p.action = #selector(ActionTarget.fire(_:))
        target.handler = { sender in
            guard let i = (sender as? NSPopUpButton)?.indexOfSelectedItem, i >= 0, i < options.count else { return }
            set(options[i].1)
        }
        targets.append(target)
        let sync: () -> Void = { [weak p] in p?.selectItem(at: options.firstIndex { $0.1 == get() } ?? 0) }
        sync()
        syncers.append(sync)
        return p
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let target = ActionTarget()
        target.handler = { _ in action() }
        targets.append(target)
        return NSButton(title: title, target: target, action: #selector(ActionTarget.fire(_:)))
    }

    // MARK: Tabs

    private func general() -> NSView {
        let s = settings
        var rows: [NSView] = [header("Providers")]
        rows.append(row([
            check("Claude", get: { s.enabledProviders.contains(.claude) }, set: { on in var p = s.enabledProviders; if on { p.insert(.claude) } else { p.remove(.claude) }; s.enabledProviders = p }),
            check("Codex", get: { s.enabledProviders.contains(.codex) }, set: { on in var p = s.enabledProviders; if on { p.insert(.codex) } else { p.remove(.codex) }; s.enabledProviders = p }),
        ]))
        rows.append(spacer())
        rows.append(header("Appearance"))
        rows.append(labeled("Popover and welcome:", popup(AppAppearance.allCases.map { ($0.title, $0) }, get: { s.appearance }, set: { s.appearance = $0 })))
        rows.append(spacer())
        rows.append(header("General"))
        let login = check("Launch at login", get: { SMAppService.mainApp.status == .enabled }, set: { on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
        })
        rows.append(login)
        rows.append(check("Check service status (status.claude.com, status.openai.com)", get: { s.statusChecks }, set: { s.statusChecks = $0 }))
        rows.append(check("Show cost on share cards", get: { s.costOnShares }, set: { s.costOnShares = $0 }))
        rows.append(spacer())
        rows.append(row([button("Show Welcome Tour…") { [weak self] in self?.openWelcome?() },
                         note("Walk through the setup again.", width: 300)]))
        return page(rows)
    }

    private func menuBar() -> NSView {
        let s = settings
        var rows: [NSView] = [header("Menu bar")]
        rows.append(labeled("Show:", popup(MenuBarMode.allCases.map { ($0.title, $0) }, get: { s.menuBarMode }, set: { s.menuBarMode = $0 })))
        rows.append(labeled("The meter tracks:", popup(MeterFocus.allCases.map { ($0.title, $0) }, get: { s.meterFocus }, set: { s.meterFocus = $0 })))
        rows.append(note("“5-hour session” fills the five cells from the session instead of the week; a small 5H tag marks it. “Whichever is tighter” switches over only while the session is the closer limit."))
        rows.append(spacer(4))
        rows.append(check("Show the percentage left beside each meter", get: { s.showPercentInMenuBar }, set: { s.showPercentInMenuBar = $0 }))
        rows.append(check("Always show the 5-hour timer while a session runs", get: { s.alwaysShowSessionTimer }, set: { s.alwaysShowSessionTimer = $0 }))
        rows.append(spacer(4))
        rows.append(note("Both providers take about 150 pt. Beside the notch macOS hides items that don't fit, so “Most urgent” shows only the provider that needs attention."))
        return page(rows)
    }

    private func session() -> NSView {
        let s = settings
        var rows: [NSView] = [header("5-hour session")]
        let warn = AppSettings.sessionWarnChoices.map { ("At \(Int(($0 * 100).rounded()))% used", $0) }
        rows.append(labeled("Warn me:", popup(warn, get: {
            AppSettings.sessionWarnChoices.min { abs($0 - s.sessionWarnAt) < abs($1 - s.sessionWarnAt) } ?? 0.75
        }, set: { s.sessionWarnAt = $0 })))
        rows.append(note("From this point the session turns amber, shows a countdown in the menu bar and, if you like, sends a notification. It turns rose at 90% (or a little after your warning, if that's later)."))
        rows.append(spacer(4))
        rows.append(labeled("On each card:", popup(SessionDetail.allCases.map { ($0 == .detailed ? "Detailed, with a forecast" : "Compact row", $0) },
                                                   get: { s.sessionDetail }, set: { s.sessionDetail = $0 })))
        rows.append(note("Detailed shows the session's timeline and where your recent pace takes it: whether it lasts to the reset, or when it runs out. Compact keeps a single row until the warning."))
        rows.append(spacer(4))
        rows.append(note("The Activity tab lists your recent sessions and which ones hit the limit. In Terminal, `headroom` prints the session forecast and `headroom wait` waits for a used-up session to come back."))
        return page(rows)
    }

    private func notifications() -> NSView {
        let s = settings
        var rows: [NSView] = [header("Notify me when")]
        for kind in NotificationKind.allCases {
            rows.append(check(kind.title, get: { s.notifies(kind) }, set: { [weak self] on in
                s.setNotifies(kind, on)
                if on { Notifier.requestAuthorization { _ in self?.refreshNotificationStatus() } }
            }))
        }
        rows.append(spacer(4))
        notifyStatus = note("")
        rows.append(notifyStatus)
        rows.append(row([button("Open Notification Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        }]))
        return page(rows)
    }

    private func advanced() -> NSView {
        var rows: [NSView] = [header("Plan price")]
        for p in Provider.allCases {
            let field = NSTextField(string: settings.planPriceOverride(p).map { String(format: "%.0f", $0) } ?? "")
            field.placeholderString = listPrice(p).map { "\(Int($0)) (list price)" } ?? "monthly USD"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            priceFields[p] = field
            rows.append(labeled("\(p.displayName) per month, USD:", field))
        }
        rows.append(note("Used for “× plan” next to this week's cost at API rates. Leave empty to use the plan's list price."))
        rows.append(spacer())
        rows.append(header("Command line"))
        cliStatus = note("", width: 300)
        rows.append(row([button("Install command line tool") { [weak self] in
            let result = CLIInstaller.install()
            self?.cliStatus.stringValue = result
            self?.refreshCLIStatus(after: result)
        }, cliStatus]))
        for tool in ["claude", "codex"] {
            let field = NSTextField(string: settings.cliPath(tool) ?? "")
            field.placeholderString = "auto-detect"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
            pathFields[tool] = field
            let label = NSTextField(labelWithString: "\(tool) path:")
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            rows.append(row([label, field, button("Choose…") { [weak self] in self?.choose(tool) }]))
        }
        rows.append(note("Headroom finds the Claude Code and Codex CLIs through your login shell. Set a path here if it can't."))
        rows.append(spacer())
        let pricing = button("Show pricing.override.json") { [weak self] in self?.revealPricing() }
        pricing.bezelStyle = .inline
        rows.append(row([note("API rates as of \(model.pricingEngine.asOf). Add or replace model prices in an override file.", width: 330), pricing]))
        return page(rows)
    }

    private func listPrice(_ p: Provider) -> Double? {
        model.faults[p]?.lastGood?.plan?.monthlyPriceUSD
    }

    // MARK: Actions

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let (p, _) = priceFields.first(where: { $0.value === field }) {
            let v = Double(field.stringValue.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
            settings.setPlanPriceOverride(field.stringValue.isEmpty ? nil : v, for: p)
        }
        if let (tool, _) = pathFields.first(where: { $0.value === field }) {
            let path = field.stringValue.trimmingCharacters(in: .whitespaces)
            settings.setCLIPath(path.isEmpty ? nil : (path as NSString).expandingTildeInPath, for: tool)
        }
    }

    private func choose(_ tool: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(tool) executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathFields[tool]?.stringValue = url.path
        settings.setCLIPath(url.path, for: tool)
    }

    private func refreshCLIStatus(after message: String? = nil) {
        Task {
            let status = await CLIInstaller.status()
            cliStatus.stringValue = [message, status].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func refreshNotificationStatus() {
        guard Notifier.available else {
            notifyStatus.stringValue = "Notifications need Headroom.app (this build runs outside an app bundle)."
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            Task { @MainActor in
                self.notifyStatus.stringValue = switch status {
                case .denied: "Notifications are turned off for Headroom in System Settings."
                case .notDetermined: "macOS asks for permission the first time you turn one on."
                default: "Each alert fires once per session or week. Headroom never repeats itself."
                }
            }
        }
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
}

/// Closure target for AppKit controls.
@MainActor
final class ActionTarget: NSObject {
    var handler: ((Any?) -> Void)?
    @objc func fire(_ sender: Any?) { handler?(sender) }
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
