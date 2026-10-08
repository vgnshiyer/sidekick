import AppKit
import PetKit
import QuartzCore
import SidekickCore

extension PetMood {
    /// The mood for the most urgent thread's status.
    init(_ status: ThreadStatus?) {
        switch status {
        case .needsInput: self = .waiting
        case .failed: self = .failed
        case .ready: self = .ready
        case .running: self = .running
        case .idle, nil: self = .idle
        }
    }
}

/// Draws the pet from its atlas with a `CALayer`, steps the animation, and turns
/// mouse input into clicks and drags.
@MainActor
final class PetSpriteView: NSView {
    private(set) var sprite: PetSprite
    private let spriteLayer = CALayer()
    private var animator: PetAnimator
    private var timer: Timer?
    private var reduceMotionObserver: NSObjectProtocol?

    /// Runs the frame timer; off while the pet is hidden.
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? step() : stopTimer()
        }
    }

    var onClick: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}

    private var pressLocation: NSPoint?
    private var lastDragLocation = NSPoint.zero
    private var dragging = false

    static let dragThreshold: CGFloat = 4

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(sprite: PetSprite) {
        self.sprite = sprite
        animator = PetAnimator(
            now: Self.now, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        super.init(frame: .zero)
        wantsLayer = true
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .linear
        spriteLayer.contentsGravity = .resize
        spriteLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        spriteLayer.contents = sprite.atlas
        layer?.addSublayer(spriteLayer)
        render()

        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let on = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.change { $0.setReduceMotion(on, at: $1) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    override func layout() {
        super.layout()
        spriteLayer.frame = bounds
    }

    func setSprite(_ newSprite: PetSprite) {
        sprite = newSprite
        spriteLayer.contents = newSprite.atlas
        render()
    }

    func setMood(_ mood: PetMood) {
        change { $0.setMood(mood, at: $1) }
    }

    func hover() {
        change { $0.hover(at: $1) }
    }

    /// Whether the pet's current frame has a visible pixel at `point` (view coordinates).
    func isOpaque(at point: NSPoint) -> Bool {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return false }
        let unit = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        return sprite.isOpaque(row: animator.row, frame: animator.frame, at: unit)
    }

    // MARK: animation

    private func change(_ body: (inout PetAnimator, TimeInterval) -> Void) {
        let before = (animator.row, animator.frame, animator.nextDeadline)
        body(&animator, Self.now)
        guard before != (animator.row, animator.frame, animator.nextDeadline) else { return }
        render()
        schedule()
    }

    private func step() {
        animator.update(at: Self.now)
        render()
        schedule()
    }

    private func schedule() {
        stopTimer()
        guard isAnimating, let deadline = animator.nextDeadline else { return }
        let interval = max(0, deadline - Self.now)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // Lets the system coalesce wakeups; a tenth of a frame is invisible.
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        spriteLayer.contentsRect = sprite.contentsRect(row: animator.row, frame: animator.frame)
    }

    // MARK: mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        lastDragLocation = NSEvent.mouseLocation
        dragging = false
        beginWindowServerDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishPress()
    }

    // MARK: window-server drag

    private var dragWatch: Timer?

    /// Hands the move to the window server at mouse-down, so it tracks the cursor from the exact press
    /// point with no lag (like a title-bar drag). A display-rate timer only reads the pointer: to tell a
    /// click from a drag, pick the run direction, and notice the release.
    private func beginWindowServerDrag(with event: NSEvent) {
        let watch = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchDrag() }
        }
        RunLoop.main.add(watch, forMode: .common)
        dragWatch = watch
        window?.performDrag(with: event)
        // performDrag may return only after the release; finishing twice is harmless.
        if NSEvent.pressedMouseButtons & 1 == 0 { finishPress() }
    }

    private func watchDrag() {
        guard let pressLocation else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishPress()
            return
        }
        let location = NSEvent.mouseLocation
        if !dragging {
            guard hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= Self.dragThreshold else { return }
            dragging = true
            onDragBegan()
        }
        let dx = location.x - lastDragLocation.x
        lastDragLocation = location
        if abs(dx) >= 0.5 {
            change { $0.drag(dx < 0 ? .left : .right, at: $1) }
        }
    }

    /// The button came up: end the drag, or treat it as a click if the pointer barely moved.
    private func finishPress() {
        dragWatch?.invalidate()
        dragWatch = nil
        guard pressLocation != nil else { return }
        pressLocation = nil
        if dragging {
            dragging = false
            change { $0.endDrag(at: $1) }
            onDragEnded()
        } else {
            onClick()
        }
    }
}
