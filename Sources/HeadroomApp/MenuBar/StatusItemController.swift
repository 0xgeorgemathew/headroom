import AppKit
import HeadroomKit

/// The single status item. Redraws only when its render key changes.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let popover: PopoverController
    var openSettings: (() -> Void)?
    private var lastKey: [MenuBarProviderModel]?

    init(model: AppModel, popover: PopoverController) {
        self.model = model
        self.popover = popover
        super.init()
        item.autosaveName = "Headroom"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        update()
    }

    func update(now: Date = Date()) {
        let presenter = Presenter(now: now)
        let items = presenter.menuBarItems(model.paceInputs(), mode: model.settings.menuBarMode,
                                           enabled: model.settings.enabledProviders, majorOutage: model.majorOutages)
        guard items != lastKey, let button = item.button else { return }
        lastKey = items
        button.image = StatusItemRenderer.image(items)
        let spoken = items.map(\.spoken).joined(separator: " ")
        button.setAccessibilityLabel(spoken.isEmpty ? "Headroom" : spoken)
        button.toolTip = items.isEmpty ? "Headroom" : nil
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            popover.toggle(relativeTo: sender)
        }
    }

    private func showMenu() {
        popover.close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Headroom", action: #selector(openPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openPopover() { if let b = item.button { popover.show(relativeTo: b) } }
    @objc private func refresh() { model.refreshNow() }
    @objc private func settings() { openSettings?() }
}
