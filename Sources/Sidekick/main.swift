import AppKit
import BridgeKit
import ClaudeKit
import CodexKit
import SidekickCore

// Sidekick              floating pet for live Claude Code and Codex threads
// Sidekick --demo       fake threads, no bridge
// Sidekick --snapshot <dir>   render the UI to PNGs offscreen, then exit

@MainActor
enum Launcher {
    static func run(_ arguments: [String]) -> Never {
        let app = NSApplication.shared

        if let index = arguments.firstIndex(of: "--snapshot") {
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("usage: Sidekick --snapshot <dir>\n".utf8))
                exit(2)
            }
            app.setActivationPolicy(.prohibited)
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            Task { exit(await Snapshot.render(to: directory) ? 0 : 1) }
            app.run()
            exit(0)
        }

        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        let controller = arguments.contains("--demo") ? demo() : live()
        controller.start()
        app.run()
        exit(0)
    }

    /// Never shown (the app has no menu bar of its own), but AppKit routes ⌘X/⌘C/⌘V/⌘A/⌘Z
    /// in the chat panel through the main menu's key equivalents.
    private static func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Sidekick", action: nil, keyEquivalent: ""))
        menu.addItem(editItem)
        return menu
    }

    private static func demo() -> AppController {
        AppController(store: ThreadStore(providers: DemoProvider.all(), persist: false), bridge: nil, persistUI: false)
    }

    private static func live() -> AppController {
        let store = ThreadStore(providers: [ClaudeProvider(), CodexProvider()])
        let bridge = BridgeServer(api: store)
        do {
            try bridge.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = error as? BridgeServer.StartError == .alreadyRunning
                ? "Sidekick is already running" : "Sidekick couldn't start its bridge"
            alert.informativeText = "Couldn't start the bridge at \(Paths.socketPath): \(error)"
            NSApp.activate()
            alert.runModal()
            exit(1)
        }
        return AppController(store: store, bridge: bridge, persistUI: true)
    }
}

MainActor.assumeIsolated {
    Launcher.run(CommandLine.arguments)
}
