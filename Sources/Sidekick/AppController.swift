import AppKit
import BridgeKit
import Combine
import PetKit
import SidekickCore

/// Wires the store to the pet panel, the chat panel and the menu bar.
@MainActor
final class AppController {
    let store: ThreadStore
    let hub: BridgeHub
    let pets: [PetPack]
    private let bridge: BridgeServer?
    private let stateStore: UIStateStore
    private let petPanel: PetPanelController
    private let chat: ChatPanelController
    private var menuBar: MenuBarController?
    private var subscription: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var awayObservers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - bridge: the running bridge server, kept alive and stopped on quit (nil in demo mode).
    ///   - persistUI: save pet choice, size and positions to `Paths.stateFile`.
    init(store: ThreadStore, bridge: BridgeServer?, hub: BridgeHub = .shared, persistUI: Bool) {
        self.store = store
        self.bridge = bridge
        self.hub = hub
        pets = PetLibrary.loadAll(from: Self.petRoots)
        stateStore = UIStateStore(file: Paths.stateFile, persist: persistUI)
        let pack = Self.pet(in: pets, preferred: stateStore.state.petId)
        petPanel = PetPanelController(sprite: Self.sprite(for: pack), quips: pack?.quips, stateStore: stateStore)
        chat = ChatPanelController(store: store)
    }

    /// Bundled pets, then the user's Sidekick pets, then their Codex pets (read-only).
    static var petRoots: [URL] {
        [
            Bundle.module.url(forResource: "Pets", withExtension: nil),
            Paths.userPetsDir,
            Paths.codexHome.appendingPathComponent("pets", isDirectory: true),
        ].compactMap { $0 }
    }

    /// The saved choice if it still exists, else "clawd", else the first pack.
    static func pet(in pets: [PetPack], preferred id: String?) -> PetPack? {
        pets.first { $0.id == id } ?? pets.first { $0.id == "clawd" } ?? pets.first
    }

    static func sprite(for pack: PetPack?) -> PetSprite {
        pack.map(PetSprite.init(pack:)) ?? .placeholder()
    }

    func start() {
        menuBar = MenuBarController(app: self)
        petPanel.onSelectThread = { [weak self] thread, anchor, growsRight in
            self?.chat.toggle(thread, anchor: anchor, growsRight: growsRight)
        }
        // The thread's own app comes forward; the mini chat and the bubbles step aside.
        petPanel.onOpenThread = { [weak self] thread in
            guard let self else { return }
            chat.close()
            petPanel.collapseTray()
            let store = store
            Task { await store.open(thread) }
        }
        petPanel.onPetInteraction = { [weak self] in self?.chat.close() }
        chat.onSent = { [weak self] in self?.petPanel.say(.sent) }
        chat.onOpened = { [weak self] in self?.petPanel.collapseTray() }
        subscription = store.$threads.sink { [weak self] threads in
            MainActor.assumeIsolated { self?.threadsChanged(threads) }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridge?.stop() }
        }
        observeAway()
        if !stateStore.state.petHidden { petPanel.show() }
        store.start()
    }

    /// While the displays sleep or the session is switched out, poll slowly and stop the pet;
    /// catch up as soon as the user is back.
    private func observeAway() {
        let away = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let back = [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        let center = NSWorkspace.shared.notificationCenter
        for name in away + back {
            let isAway = away.contains(name)
            awayObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAway(isAway) }
            })
        }
    }

    private func setAway(_ away: Bool) {
        petPanel.screensAwake = !away
        if away {
            store.start(interval: 10)
        } else {
            store.start()
        }
    }

    private func threadsChanged(_ threads: [AgentThread]) {
        petPanel.update(threads: threads, mood: PetMood(threads.first?.status))
        chat.threadsChanged(threads)
    }

    // MARK: menu actions

    var selectedPet: PetPack? { Self.pet(in: pets, preferred: stateStore.state.petId) }
    var isPetVisible: Bool { petPanel.isVisible }
    var petSize: PetSize { stateStore.state.petSize }

    func selectPet(id: String) {
        guard let pack = pets.first(where: { $0.id == id }) else { return }
        stateStore.update { $0.petId = id }
        petPanel.setSprite(Self.sprite(for: pack), quips: pack.quips)
    }

    func setPetVisible(_ visible: Bool) {
        stateStore.update { $0.petHidden = !visible }
        if visible {
            petPanel.show()
        } else {
            chat.close()
            petPanel.hide()
        }
    }

    func setPetSize(_ size: PetSize) {
        petPanel.setSize(size)
    }
}
