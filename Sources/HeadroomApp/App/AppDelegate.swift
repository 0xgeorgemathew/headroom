import AppKit
import ServiceManagement
import HeadroomKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var popover: PopoverController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        model = AppModel(settings: settings)
        popover = PopoverController(model: model)
        statusItem = StatusItemController(model: model, popover: popover)
        let open: () -> Void = { [weak self] in self?.showSettings() }
        popover.openSettings = open
        statusItem.openSettings = open
        statusItem.openWelcome = { [weak self] in self?.showOnboarding() }
        model.onChange = { [weak self] in
            self?.statusItem.update()
            self?.popover.refresh()
            self?.onboarding?.refresh()
            self?.settingsWindow?.refresh()
        }
        settings.onChange = { [weak self] in
            self?.model.settingsChanged()
        }
        model.start()
        // Test hook for measurements and screenshots: `open Headroom.app --args --open-popover [--tab 1]`.
        let args = ProcessInfo.processInfo.arguments
        // Test hook: `--cycle-popover` opens for 10 s every 30 s (memory soak).
        if args.contains("--cycle-popover") {
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let button = self.statusItem.item.button else { return }
                    self.settings.lastTab = (self.settings.lastTab + 1) % 2
                    self.popover.show(relativeTo: button)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.popover.close() }
                }
            }
        }
        // First launch (or `--welcome`): the welcome window, once the menu bar item is in place.
        if !settings.onboardingCompleted || args.contains("--welcome") {
            let step = args.firstIndex(of: "--welcome-step").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showOnboarding(step: step) }
        }
        // Test hook: `--open-settings [--settings-section N]`.
        if args.contains("--open-settings") {
            let section = args.firstIndex(of: "--settings-section").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.showSettings(section: section) }
        }
        if args.contains("--register-login-item") {
            try? SMAppService.mainApp.register()
        }
        if args.contains("--open-popover") {
            if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let t = Int(args[i + 1]) { settings.lastTab = t }
            let delay = args.firstIndex(of: "--open-after").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let button = self.statusItem.item.button else { return }
                self.popover.show(relativeTo: button)
                if let i = args.firstIndex(of: "--close-after"), i + 1 < args.count, let secs = Double(args[i + 1]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.popover.close() }
                }
            }
        }
    }

    func showOnboarding(step: Int = 0) {
        if onboarding == nil {
            let controller = OnboardingWindowController(settings: settings, model: model)
            controller.onFinish = { [weak self] completed in
                guard let self else { return }
                self.onboarding = nil
                self.settingsWindow?.refresh()
                // Show where Headroom lives.
                if completed, let button = self.statusItem.item.button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.popover.show(relativeTo: button) }
                }
            }
            onboarding = controller
        }
        onboarding?.show(step: step)
    }

    func showSettings(section: Int? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, model: model)
            settingsWindow?.openWelcome = { [weak self] in self?.showOnboarding() }
        }
        settingsWindow?.show(section: section)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.flushOnQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
