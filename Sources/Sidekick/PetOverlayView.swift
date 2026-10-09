import AppKit
import PetKit
import SidekickCore
import SwiftUI

/// The pet panel's content: the sprite, the attention badge, the quip and the bubble tray.
@MainActor
final class PetOverlayView: NSView {
    let spriteView: PetSpriteView
    let trayModel = TrayModel()
    let quipModel = QuipModel()
    private let trayHost: FirstMouseHostingView<TrayView>
    private let quipHost: NSHostingView<QuipView>
    private let badgeHost = NSHostingView(rootView: CountBadge(count: 0))
    /// The badge's size for its count. `badgeHost` takes no size of its own, so its `fittingSize` is zero.
    private var badgeSize = CGSize.zero
    private(set) var layout: PetOverlayLayout?

    init(sprite: PetSprite, surface: SurfaceStyle = .live) {
        spriteView = PetSpriteView(sprite: sprite)
        trayHost = FirstMouseHostingView(rootView: TrayView(model: trayModel, surface: surface))
        quipHost = NSHostingView(rootView: QuipView(model: quipModel, surface: surface))
        super.init(frame: .zero)
        badgeHost.sizingOptions = []
        badgeHost.isHidden = true
        quipHost.sizingOptions = []
        quipHost.isHidden = true
        trayHost.isHidden = true
        addSubview(trayHost)
        addSubview(spriteView)
        addSubview(quipHost)
        addSubview(badgeHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lay out for `layout`, with the tray showing `threads` and the badge showing `badgeCount` (0 hides it).
    func apply(_ layout: PetOverlayLayout, threads: [AgentThread], badgeCount: Int) {
        self.layout = layout
        frame.size = layout.panelFrame.size
        spriteView.frame = layout.petFrame

        if let trayFrame = layout.trayFrame {
            trayModel.threads = threads
            trayModel.placement = layout.placement
            trayModel.tailX = layout.tailX - TrayMetrics.margin.width
            trayHost.frame = trayFrame
            trayHost.isHidden = false
        } else {
            trayHost.isHidden = true
            trayModel.threads = []
            trayModel.bubbleFrames = [:]
            trayModel.hoveredId = nil
        }

        if let quipFrame = layout.quipFrame {
            quipModel.side = layout.quipSide
            quipHost.frame = quipFrame
            quipHost.isHidden = false
        } else {
            quipHost.isHidden = true
        }

        badgeHost.isHidden = badgeCount == 0
        if let badge = badgeFrame(count: badgeCount, pet: layout.petFrame) {
            // Kept inside the panel.
            badgeHost.frame = CGRect(
                x: min(max(badge.minX, bounds.minX), bounds.maxX - badge.width),
                y: min(max(badge.minY, bounds.minY), bounds.maxY - badge.height),
                width: badge.width, height: badge.height)
        }
    }

    /// Where the badge showing `count` sits for a pet at `pet` (any coordinate space): on the top-right
    /// corner of the resting art, like an app-icon badge. Nil when `count` is 0.
    func badgeFrame(count: Int, pet: CGRect) -> CGRect? {
        guard count > 0 else { return nil }
        if badgeHost.rootView.count != count {
            badgeHost.rootView = CountBadge(count: count)
            badgeSize = NSHostingView(rootView: CountBadge(count: count)).fittingSize
        }
        let size = badgeSize
        let art = restingArt(in: pet)
        return CGRect(x: art.maxX - size.width / 2 - 3, y: art.maxY - size.height / 2 - 3, width: size.width, height: size.height)
    }

    /// The resting art's bounds in unit coordinates of the pet's frame.
    var restingArtUnitFrame: CGRect {
        spriteView.sprite.opaqueBounds(row: .idle, frame: 0) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func restingArt(in pet: CGRect) -> CGRect {
        let art = restingArtUnitFrame
        return CGRect(
            x: pet.minX + art.minX * pet.width, y: pet.minY + art.minY * pet.height,
            width: art.width * pet.width, height: art.height * pet.height)
    }

    // MARK: hit-testing (view coordinates)

    /// The visible part of the pet at rest. Steadier than per-frame pixels, so it decides hover.
    var restingArtFrame: CGRect { restingArt(in: spriteView.frame) }

    /// On the pet's visible pixels or its badge.
    func petContains(_ point: NSPoint) -> Bool {
        if !badgeHost.isHidden, badgeHost.frame.contains(point) { return true }
        return spriteView.isOpaque(at: convert(point, to: spriteView))
    }

    /// The thread whose bubble shows at `point`, if any.
    func bubble(at point: NSPoint) -> String? {
        guard !trayHost.isHidden, trayHost.frame.contains(point) else { return nil }
        let local = trayHost.convert(point, from: self)
        return trayModel.bubbleFrames.first { $0.value.intersection(trayHost.bounds).contains(local) }?.key
    }

    /// Anywhere on the visible stack of bubbles, the gaps between them included, so a scroll that
    /// slides a gap under a still pointer keeps scrolling the tray instead of the window behind it.
    func bubbleContains(_ point: NSPoint) -> Bool {
        guard !trayHost.isHidden, trayHost.frame.contains(point) else { return false }
        let local = trayHost.convert(point, from: self)
        let stack = trayModel.bubbleFrames.values
            .map { $0.intersection(trayHost.bounds) }
            .filter { !$0.isNull && !$0.isEmpty }
            .reduce(CGRect.null) { $0.union($1) }
        return stack.contains(local)
    }

    /// A bubble's frame in screen coordinates.
    func screenFrame(ofBubble id: String) -> CGRect? {
        guard let window, let frame = trayModel.bubbleFrames[id] else { return nil }
        return window.convertToScreen(trayHost.convert(frame.intersection(trayHost.bounds), to: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if petContains(local) { return spriteView }
        // The panel only takes the mouse over the bubbles (or for the rest of a scroll that began
        // there), so anything that reaches the tray's area belongs to its scroll view.
        if !trayHost.isHidden, trayHost.frame.contains(local) { return trayHost.hitTest(local) }
        return nil
    }
}

/// Count of threads that need attention, shown while the tray is collapsed.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
            .padding(2)
            .accessibilityLabel("\(count) threads need attention")
    }
}
