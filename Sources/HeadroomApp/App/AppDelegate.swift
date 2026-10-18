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
