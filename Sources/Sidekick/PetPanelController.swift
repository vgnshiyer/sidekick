import AppKit
import PetKit
import SidekickCore
import SwiftUI

/// Floating, click-through panel that never takes focus.
final class PetPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        // Sidekick is never the active app; without this the Open buttons' tooltips never show.
        allowsToolTipsWhenApplicationIsInactive = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the pet panel: placement per display, dragging, click-through, the tray and quips.
@MainActor
final class PetPanelController {
    let panel = PetPanel()
    let overlay: PetOverlayView
    private let stateStore: UIStateStore

    /// Bottom-left of the pet on screen.
    private var petOrigin = CGPoint.zero
    private var threads: [AgentThread] = []
    private var attentionCount = 0
    private var mood = PetMood.idle
    private var quips: PetQuips?
    private var quipThrottle = QuipThrottle()
    /// The bubble's size while a quip shows; the panel grows to hold it.
    private var quipSize: CGSize?
    private var quipTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var pointerOverPet = false
    private var dragging = false
    /// Pet origin minus panel origin, fixed for the length of a drag.
    private var dragOffset = CGVector.zero

    /// A bubble was clicked: the thread, the bubble's screen frame, and whether the tray grows rightwards.
    var onSelectThread: (AgentThread, CGRect, Bool) -> Void = { _, _, _ in }
    /// A bubble's Open button was clicked: show the thread in its own app.
    var onOpenThread: (AgentThread) -> Void = { _ in }
    /// The pet was clicked or started moving; the chat should get out of the way.
    var onPetInteraction: () -> Void = {}
    /// False while the displays sleep or the user's session is switched out.
    var screensAwake = true {
        didSet { updateAnimation() }
    }

    init(sprite: PetSprite, quips: PetQuips?, stateStore: UIStateStore) {
        self.stateStore = stateStore
        self.quips = quips
        overlay = PetOverlayView(sprite: sprite)
        panel.contentView = overlay

        overlay.trayModel.onSelect = { [weak self] thread in self?.select(thread) }
        overlay.trayModel.onOpen = { [weak self] thread in self?.onOpenThread(thread) }
        // Hover follows the bubbles, not only the mouse. Hover changes no frames, so this doesn't loop.
        overlay.trayModel.onFramesChanged = { [weak self] in self?.updatePointer(NSEvent.mouseLocation) }
        let spriteView = overlay.spriteView
        spriteView.onClick = { [weak self] in
            self?.dismissQuip(animated: false)
            // A click can still nudge the panel a few points under the window server; put it back.
            self?.relayout()
            self?.toggleCollapsed()
        }
        spriteView.onDragBegan = { [weak self] in
            guard let self else { return }
            dragging = true
            // The pet's place in the panel, which the window server moves as a whole.
            dragOffset = CGVector(dx: overlay.spriteView.frame.minX, dy: overlay.spriteView.frame.minY)
            // Mid-drag the panel keeps its frame; it shrinks back once the pet is dropped.
            dismissQuip(animated: false)
            onPetInteraction()
        }
        spriteView.onDragEnded = { [weak self] in
            guard let self else { return }
            dragging = false
            // The window server may have moved the panel; the pet keeps its place inside it.
            petOrigin = CGPoint(x: panel.frame.minX + dragOffset.dx, y: panel.frame.minY + dragOffset.dy)
            savePosition()
            relayout()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePosition() }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnimation() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        restorePosition()
        // Occlusion updates arrive after ordering in; start optimistically.
        overlay.spriteView.isAnimating = screensAwake
        startMonitors()
        updatePointer(NSEvent.mouseLocation)
    }

    /// Hides the panel and empties the tray, so nothing renders while the pet is away.
    func hide() {
        dismissQuip(animated: false)
        stopMonitors()
        panel.orderOut(nil)
        updateAnimation()
        relayout()
    }

    /// Animate only while some of the panel can be seen.
    private func updateAnimation() {
        overlay.spriteView.isAnimating = screensAwake && panel.isVisible && panel.occlusionState.contains(.visible)
    }

    func update(threads: [AgentThread], mood: PetMood) {
        self.threads = threads
        attentionCount = threads.filter { $0.status.wantsAttention }.count
        let startedWorking = mood == .running && self.mood != .running
        self.mood = mood
        overlay.spriteView.setMood(mood)
        relayout()
        if startedWorking { say(.working) }
    }

    func setSprite(_ sprite: PetSprite, quips: PetQuips?) {
        dismissQuip(animated: false)
        self.quips = quips
        overlay.spriteView.setSprite(sprite)
        relayout()
    }

    func setSize(_ size: PetSize) {
        stateStore.update { $0.petSize = size }
        savePosition()
        relayout()
    }

    /// Hide the bubbles (the pet keeps its attention badge) until the pet is clicked again.
    func collapseTray() {
        guard !stateStore.state.trayCollapsed, !dragging else { return }
        stateStore.update { $0.trayCollapsed = true }
        relayout()
    }

    func toggleCollapsed() {
        onPetInteraction()
        // With no threads there is nothing to collapse; don't leave a hidden tray behind for later.
        guard !threads.isEmpty || stateStore.state.trayCollapsed else { return }
        stateStore.update { $0.trayCollapsed.toggle() }
        relayout()
    }

    // MARK: quips

    /// Pops the pet's line for `trigger` up beside its head for a few seconds. Skipped when the pet
    /// has no such line, is hidden or being dragged, or spoke less than `QuipThrottle.interval` ago.
    func say(_ trigger: QuipTrigger) {
        guard let text = quips?.text(for: trigger), panel.isVisible, screensAwake, !dragging,
              quipThrottle.allow(at: ProcessInfo.processInfo.systemUptime) else { return }
        dismissQuip(animated: false)
        overlay.quipModel.text = text
        quipSize = QuipMetrics.size(for: text)
        // Grow the panel first; the bubble pops in once its host sits at its new frame.
        relayout()
        quipTask = Task { [weak self] in
            // Taken down before it got to pop in.
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: QuipMetrics.popDuration, bounce: 0.2)) { self?.overlay.quipModel.isShown = true }
            try? await Task.sleep(for: .seconds(QuipMetrics.popDuration + QuipMetrics.holdDuration))
            guard !Task.isCancelled else { return }
            self?.dismissQuip(animated: true)
        }
    }

    /// Takes the quip down, fading it out when `animated`, then shrinks the panel back.
    private func dismissQuip(animated: Bool) {
        quipTask?.cancel()
        quipTask = nil
        guard quipSize != nil else { return }
        guard animated else {
            overlay.quipModel.isShown = false
            quipSize = nil
            relayout()
            return
        }
        withAnimation(.easeOut(duration: QuipMetrics.fadeDuration)) {
            overlay.quipModel.isShown = false
        } completion: { [weak self] in
            guard let self, !overlay.quipModel.isShown else { return }
            quipSize = nil
            relayout()
        }
    }

    // MARK: placement

    private var petSize: CGSize { stateStore.state.petSize.points }
    private var petRect: CGRect { CGRect(origin: petOrigin, size: petSize) }

    /// Put the pet back where it was on its display, or bottom-left of the main display.
    func restorePosition() {
        let screens = NSScreen.screens
        let state = stateStore.state
        guard let screen = screens.first(where: { $0.displayKey == state.lastDisplay }) ?? screens.first else { return }
        let visible = screen.visibleFrame
        if let saved = state.positions[screen.displayKey] {
            petOrigin = PetPosition.origin(normalized: saved, size: petSize, in: visible)
        } else {
            petOrigin = PetPosition.defaultOrigin(in: visible)
        }
        relayout()
    }

    private func savePosition() {
        guard let screen = screen(for: petRect) else { return }
        let visible = screen.visibleFrame
        petOrigin = PetPosition.clamp(petOrigin, size: petSize, in: visible)
        let normalized = PetPosition.normalize(petOrigin, size: petSize, in: visible)
        stateStore.update {
            $0.positions[screen.displayKey] = normalized
            $0.lastDisplay = screen.displayKey
        }
    }

    private func relayout() {
        guard !dragging, let screen = screen(for: petRect) else { return }
        let collapsed = stateStore.state.trayCollapsed
        let badgeCount = collapsed ? attentionCount : 0
        let quip = quipSize.map { size in
            QuipRequest(
                size: size, margin: QuipMetrics.margin, head: overlay.restingArtUnitFrame,
                avoiding: overlay.badgeFrame(count: badgeCount, pet: petRect).map { [$0] } ?? [])
        }
        let layout = PetOverlayLayout(
            pet: petRect, art: overlay.spriteView.sprite.trayAnchor,
            tray: collapsed ? nil : TrayMetrics.preferredSize(rows: threads.count),
            margin: TrayMetrics.margin, gap: TrayMetrics.gap, screen: screen.visibleFrame, petPadding: TrayMetrics.petPadding,
            quip: quip)
        // Lay the content out before moving the panel, so the frame change and the content that
        // keeps the pet in place reach the screen together.
        overlay.apply(layout, threads: panel.isVisible ? threads : [], badgeCount: badgeCount)
        panel.setFrame(layout.panelFrame, display: true)
        updatePointer(NSEvent.mouseLocation)
    }

    private func screen(for rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screens = NSScreen.screens
        return screens.first { $0.frame.contains(center) }
            ?? screens.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private func select(_ thread: AgentThread) {
        guard let frame = overlay.screenFrame(ofBubble: thread.id) else { return }
        onSelectThread(thread, frame, overlay.layout?.trayGrowsRight ?? true)
    }

    // MARK: click-through

    private func startMonitors() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
            return event
        }) {
            monitors.append(local)
        }
        // Global monitors only see clicks in other apps and on the desktop, never on Sidekick's own
        // panels, so clicking a bubble or the chat never dismisses anything.
        if let clickAway = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.collapseTray() }
            }) {
            monitors.append(clickAway)
        }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Accept the mouse only over the pet's visible pixels and the bubbles, and mark the bubble
    /// under the pointer.
    private func updatePointer(_ location: NSPoint) {
        guard panel.isVisible else { return }
        guard !dragging else {
            panel.ignoresMouseEvents = false
            return
        }
        let point = overlay.convert(panel.convertPoint(fromScreen: location), from: nil)
        let overPet = overlay.restingArtFrame.contains(point)
        if overPet, !pointerOverPet { overlay.spriteView.hover() }
        pointerOverPet = overPet
        let bubble = overlay.bubble(at: point)
        if overlay.trayModel.hoveredId != bubble { overlay.trayModel.hoveredId = bubble }
        let interactive = overlay.petContains(point) || bubble != nil
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }
}
