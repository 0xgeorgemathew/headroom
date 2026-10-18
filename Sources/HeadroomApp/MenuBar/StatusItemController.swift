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
    private var lastAppearanceDark: Bool?
    private var lastScale: CGFloat = 0
    private var appearanceObservation: NSKeyValueObservation?

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
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update(force: true) }
            }
        }
        update()
    }

    func update(now: Date = Date(), force: Bool = false) {
        let presenter = Presenter(now: now)
        let items = presenter.menuBarItems(model.paceInputs(), mode: model.settings.menuBarMode,
                                           enabled: model.settings.enabledProviders, majorOutage: model.majorOutages)
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard force || items != lastKey || dark != lastAppearanceDark || scale != lastScale else { return }
        lastKey = items
        lastAppearanceDark = dark
        lastScale = scale
        let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
        // Touch the item only when something actually changed, and keep its width stable:
        // every relayout makes AppKit re-render the status button.
        if abs(item.length - (size.width + 8)) > 0.5 { item.length = size.width + 8 }
        // A finished CPU-rendered bitmap; AppKit only composites it.
        if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: scale) {
            let image = NSImage(cgImage: cg, size: size)
            image.isTemplate = false
            button.image = image
        }
        let spoken = items.map(\.spoken).joined(separator: " ")
        let label = spoken.isEmpty ? "Headroom" : spoken
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let tip: String? = items.isEmpty ? "Headroom" : nil
        if button.toolTip != tip { button.toolTip = tip }
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
