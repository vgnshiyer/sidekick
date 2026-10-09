import AppKit
import CodexKit
import SidekickCore

/// The menu bar's logo menu: pet choice, visibility, size, bridge status and Quit.
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
        statusItem.button?.image = Self.logoTemplate()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        claudeStatus.isEnabled = false
        codexStatus.isEnabled = false
    }

    /// The logo's pal and status bubble in one color, with the eyes and the three dots cut out.
    /// Drawn in the logo's 1024-unit coordinates (body cropped above the tile's edge), fitted to 18 pt.
    static func logoTemplate() -> NSImage {
        let content = CGRect(x: 290, y: 206, width: 540, height: 634)
        let height: CGFloat = 18
        let scale = height / content.height
        let image = NSImage(size: CGSize(width: (content.width * scale).rounded(.up), height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -content.minX, y: -content.minY)

            let shape = CGMutablePath()
            shape.move(to: CGPoint(x: 300, y: 840))
            shape.addLine(to: CGPoint(x: 300, y: 640))
            shape.addQuadCurve(to: CGPoint(x: 470, y: 470), control: CGPoint(x: 300, y: 470))
            shape.addLine(to: CGPoint(x: 554, y: 470))
            shape.addQuadCurve(to: CGPoint(x: 724, y: 640), control: CGPoint(x: 724, y: 470))
            shape.addLine(to: CGPoint(x: 724, y: 840))
            shape.closeSubpath()
            shape.addRoundedRect(in: CGRect(x: 520, y: 216, width: 300, height: 180), cornerWidth: 90, cornerHeight: 90)
            shape.addLines(between: [CGPoint(x: 560, y: 380), CGPoint(x: 530, y: 446), CGPoint(x: 612, y: 390)])
            shape.closeSubpath()
            context.setFillColor(.black)
            context.addPath(shape)
            context.fillPath()

            // Larger than the logo's so they stay open at 18 pt.
            context.setBlendMode(.clear)
            for x in [438.0, 586.0] {
                context.fillEllipse(in: CGRect(x: x - 40, y: 640 - 54, width: 80, height: 108))
            }
            for x in [585.0, 670.0, 755.0] {
                context.fillEllipse(in: CGRect(x: x - 31, y: 306 - 31, width: 62, height: 62))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sidekick"
        return image
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
