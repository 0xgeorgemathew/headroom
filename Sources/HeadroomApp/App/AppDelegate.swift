import AppKit
import HeadroomKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var popover: PopoverController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        model = AppModel(settings: settings)
        popover = PopoverController(model: model)
        statusItem = StatusItemController(model: model, popover: popover)
        let open: () -> Void = { [weak self] in self?.showSettings() }
        popover.openSettings = open
        statusItem.openSettings = open
        model.onChange = { [weak self] in
            self?.statusItem.update()
            self?.popover.refresh()
        }
        settings.onChange = { [weak self] in
            self?.model.settingsChanged()
        }
        model.start()
        // Test hook for measurements and screenshots: `open Headroom.app --args --open-popover [--tab 1]`.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--open-popover") {
            if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let t = Int(args[i + 1]) { settings.lastTab = t }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let button = self.statusItem.item.button else { return }
                self.popover.show(relativeTo: button)
            }
        }
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(settings: settings, model: model) }
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.flushOnQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
