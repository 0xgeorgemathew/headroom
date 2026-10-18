import AppKit
import HeadroomCore
import HeadroomKit
import ServiceManagement

/// Settings (PLAN §9, completion list): providers, menu bar mode, plan prices, status checks,
/// cost on shares, launch at login, CLI install and CLI path overrides.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings: AppSettings
    private let model: AppModel
    private var claudeToggle: NSButton!
    private var codexToggle: NSButton!
    private var modePopup: NSPopUpButton!
    private var priceFields: [Provider: NSTextField] = [:]
    private var statusToggle: NSButton!
    private var costToggle: NSButton!
    private var loginToggle: NSButton!
    private var cliStatus: NSTextField!
    private var pathFields: [String: NSTextField] = [:]

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Headroom Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
        refreshCLIStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func section(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 460
        return l
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        // Providers
        stack.addArrangedSubview(section("Providers"))
        let enabled = settings.enabledProviders
        claudeToggle = check("Claude", enabled.contains(.claude), #selector(providersChanged))
        codexToggle = check("Codex", enabled.contains(.codex), #selector(providersChanged))
        stack.addArrangedSubview(row([claudeToggle, codexToggle]))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // Menu bar
        stack.addArrangedSubview(section("Menu bar"))
        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in MenuBarMode.allCases { modePopup.addItem(withTitle: m.title) }
        modePopup.selectItem(at: MenuBarMode.allCases.firstIndex(of: settings.menuBarMode) ?? 0)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        stack.addArrangedSubview(row([NSTextField(labelWithString: "Show:"), modePopup]))
        stack.addArrangedSubview(note("Both providers take about 150 pt. Beside the notch macOS hides items that don't fit, so “Most urgent” shows only the provider that needs attention."))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // Plan price
        stack.addArrangedSubview(section("Plan price"))
        for p in Provider.allCases {
            let field = NSTextField(string: settings.planPriceOverride(p).map { String(format: "%.0f", $0) } ?? "")
            field.placeholderString = listPrice(p).map { "\(Int($0)) (list price)" } ?? "monthly USD"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            priceFields[p] = field
            let label = NSTextField(labelWithString: "\(p.displayName) per month, USD:")
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true
            stack.addArrangedSubview(row([label, field]))
        }
        stack.addArrangedSubview(note("Used for “× plan” next to this week's cost at API rates. Leave empty to use the plan's list price."))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // Status, sharing, login
        stack.addArrangedSubview(section("General"))
        statusToggle = check("Check service status (status.claude.com, status.openai.com)", settings.statusChecks, #selector(statusChanged))
        costToggle = check("Show cost on share cards", settings.costOnShares, #selector(costChanged))
        loginToggle = check("Launch at login", SMAppService.mainApp.status == .enabled, #selector(loginChanged))
        stack.addArrangedSubview(statusToggle)
        stack.addArrangedSubview(costToggle)
        stack.addArrangedSubview(loginToggle)
        stack.setCustomSpacing(16, after: loginToggle)

        // CLI
        stack.addArrangedSubview(section("Command line"))
        let install = NSButton(title: "Install command line tool", target: self, action: #selector(installCLI))
        cliStatus = NSTextField(wrappingLabelWithString: "")
        cliStatus.font = .systemFont(ofSize: 11)
        cliStatus.textColor = .secondaryLabelColor
        cliStatus.preferredMaxLayoutWidth = 280
        stack.addArrangedSubview(row([install, cliStatus]))
        for tool in ["claude", "codex"] {
            let field = NSTextField(string: settings.cliPath(tool) ?? "")
            field.placeholderString = "auto-detect"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
            pathFields[tool] = field
            let choose = NSButton(title: "Choose…", target: self, action: tool == "claude" ? #selector(chooseClaude) : #selector(chooseCodex))
            let label = NSTextField(labelWithString: "\(tool) path:")
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            stack.addArrangedSubview(row([label, field, choose]))
        }
        stack.addArrangedSubview(note("Headroom finds the Claude Code and Codex CLIs through your login shell. Set a path here if it can't."))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        let pricing = NSButton(title: "Show pricing.override.json", target: self, action: #selector(revealPricing))
        pricing.bezelStyle = .inline
        stack.addArrangedSubview(row([note("API rates as of \(model.pricingEngine.asOf). Add or replace model prices in an override file."), pricing]))

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 540),
        ])
        return container
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 10
        r.alignment = .firstBaseline
        return r
    }

    private func listPrice(_ p: Provider) -> Double? {
        model.faults[p]?.lastGood?.plan?.monthlyPriceUSD
    }

    // MARK: Actions

    @objc private func providersChanged() {
        var set = Set<Provider>()
        if claudeToggle.state == .on { set.insert(.claude) }
        if codexToggle.state == .on { set.insert(.codex) }
        settings.enabledProviders = set
    }

    @objc private func modeChanged() {
        settings.menuBarMode = MenuBarMode.allCases[max(modePopup.indexOfSelectedItem, 0)]
    }

    @objc private func statusChanged() { settings.statusChecks = statusToggle.state == .on }
    @objc private func costChanged() { settings.costOnShares = costToggle.state == .on }

    @objc private func loginChanged() {
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSSound.beep()
        }
    }

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

    @objc private func chooseClaude() { choose("claude") }
    @objc private func chooseCodex() { choose("codex") }

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

    @objc private func installCLI() {
        let result = CLIInstaller.install()
        cliStatus.stringValue = result
        refreshCLIStatus(after: result)
    }

    private func refreshCLIStatus(after message: String? = nil) {
        Task {
            let status = await CLIInstaller.status()
            cliStatus.stringValue = [message, status].compactMap { $0 }.joined(separator: "\n")
        }
    }

    @objc private func revealPricing() {
        let url = PriceTable.defaultOverrideURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = #"{"as_of": "2026-10-18", "models": {}, "aliases": {}}"# + "\n"
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
