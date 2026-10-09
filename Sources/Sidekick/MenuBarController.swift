import AppKit
import CodexKit
import SidekickCore

/// The pawprint menu: pet choice, visibility, size, bridge status and Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private unowned let app: AppController
    private let claudeStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var claudeSessions = 0
    private var codexHooksInstalled = false

    init(app: AppController) {
        self.app = app
        super.init()
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Sidekick")
        image?.isTemplate = true
        statusItem.button?.image = image
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        claudeStatus.isEnabled = false
        codexStatus.isEnabled = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Refresh the bridge lines; the Claude count updates in place while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        codexHooksInstalled = CodexHooks.isInstalled()
        updateBridgeStatus()
        let hub = app.hub
        Task {
            claudeSessions = await hub.liveClaudeSessionCount
            updateBridgeStatus()
        }
    }

    private func updateBridgeStatus() {
        let sessions = claudeSessions == 1 ? "1 session" : "\(claudeSessions) sessions"
        claudeStatus.title = "Claude bridge: \(sessions) connected"
        codexStatus.title = codexHooksInstalled ? "Codex hooks: installed" : "Codex hooks: not installed"
    }

    private func rebuild() {
        menu.removeAllItems()

        let pets = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
        let petsMenu = NSMenu()
        if app.pets.isEmpty {
            petsMenu.addItem(disabled("No pets installed"))
        }
        for pack in app.pets {
            let item = NSMenuItem(title: pack.displayName, action: #selector(selectPet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == app.selectedPet?.id ? .on : .off
            item.toolTip = pack.description.isEmpty ? nil : pack.description
            petsMenu.addItem(item)
        }
        pets.submenu = petsMenu
        menu.addItem(pets)

        let visibility = NSMenuItem(
            title: app.isPetVisible ? "Hide Pet" : "Show Pet", action: #selector(togglePet), keyEquivalent: "")
        visibility.target = self
        menu.addItem(visibility)

        let size = NSMenuItem(title: "Pet Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for option in PetSize.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == app.petSize ? .on : .off
            sizeMenu.addItem(item)
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        menu.addItem(.separator())
        updateBridgeStatus()
        menu.addItem(claudeStatus)
        menu.addItem(codexStatus)


        menu.addItem(.separator())
        let phone = NSMenuItem(title: "Phone Access…", action: #selector(showPhone), keyEquivalent: "")
        phone.target = self
        phone.state = app.phone.isOn ? .on : .off
        menu.addItem(phone)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sidekick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        app.selectPet(id: id)
    }

    @objc private func showPhone() {
        app.phone.showWindow()
    }

    @objc private func togglePet() {
        app.setPetVisible(!app.isPetVisible)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PetSize(rawValue: raw) else { return }
        app.setPetSize(size)
    }
}
