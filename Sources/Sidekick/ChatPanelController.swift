import AppKit
import PetKit
import SidekickCore

/// Non-activating panel that can still become key, so typing works while the
/// terminal or editor stays the active app.
final class ChatPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: ChatView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own soft shadow; a window shadow would trace the panel's square bounds.
        hasShadow = false
        // The app stays inactive while the chat is up; without this its buttons' tooltips never show.
        allowsToolTipsWhenApplicationIsInactive = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// Shows one thread's chat next to its bubble.
@MainActor
final class ChatPanelController {
    private let store: ThreadStore
    private let panel = ChatPanel()
    private var model: ChatModel?
    /// Watches clicks in other apps while the chat is open, to close it on a click away.
    private var clickAwayMonitor: Any?
    /// A message from the chat was delivered or queued.
    var onSent: () -> Void = {}
    /// The user chose "Open in …" in the chat.
    var onOpened: () -> Void = {}

    init(store: ThreadStore) {
        self.store = store
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// The thread whose chat is open, if any.
    var openThreadId: String? { panel.isVisible ? model?.thread.id : nil }

    /// Open the chat for `thread` beside `anchor` (screen coordinates), or close it if it is already open.
    func toggle(_ thread: AgentThread, anchor: CGRect, growsRight: Bool) {
        if openThreadId == thread.id {
            close()
        } else {
            show(thread, anchor: anchor, growsRight: growsRight)
        }
    }

    func show(_ thread: AgentThread, anchor: CGRect, growsRight: Bool) {
        store.acknowledge(thread)
        store.onScreen = thread.id
        let model = ChatModel(thread: store.thread(id: thread.id) ?? thread, store: store)
        model.onClose = { [weak self] in self?.close() }
        model.onSent = { [weak self] in self?.onSent() }
        model.onOpened = { [weak self] in self?.onOpened() }
        self.model = model
        // Transparent room around the glass so its shadow isn't cut off at the window edge.
        let pad = ChatView.shadowPadding
        panel.contentView = FirstMouseHostingView(rootView: ChatView(model: model).padding(pad))

        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let chat = PetOverlayLayout.panelFrame(size: ChatView.size, beside: anchor, growsRight: growsRight, screen: visible)
            panel.setFrame(chat.insetBy(dx: -pad, dy: -pad), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        startClickAwayMonitor()
        model.reload()
    }

    func close() {
        stopClickAwayMonitor()
        panel.orderOut(nil)
        panel.contentView = nil
        model = nil
        store.onScreen = nil
    }

    /// A global monitor only sees clicks in other apps' windows (and the desktop), never Sidekick's own,
    /// so clicking another bubble still switches the chat instead of closing it.
    private func startClickAwayMonitor() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopClickAwayMonitor() {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
    }

    /// Keep the open chat in step with the store.
    func threadsChanged(_ threads: [AgentThread]) {
        guard let model, let thread = threads.first(where: { $0.id == model.thread.id }) else { return }
        model.update(thread)
    }
}
