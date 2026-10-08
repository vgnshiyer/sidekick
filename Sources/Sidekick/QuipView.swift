import PetKit
import SwiftUI

/// Sizes and timings of the quip bubble beside the pet's head.
enum QuipMetrics {
    static let font = Font.system(size: 12.5, weight: .semibold)
    /// Longer lines are truncated.
    static let maxTextWidth: CGFloat = 220
    /// Room around the bubble for its shadow.
    static let margin = CGSize(width: 12, height: 12)
    static let popDuration: TimeInterval = 0.18
    static let holdDuration: TimeInterval = 2.6
    static let fadeDuration: TimeInterval = 0.25

    /// The bubble's size for `text`, tail included.
    @MainActor
    static func size(for text: String) -> CGSize {
        NSHostingView(rootView: QuipBubble(text: text, side: .right).environment(\.surfaceStyle, .snapshot)).fittingSize
    }
}

/// What the quip shows; owned by the pet panel.
@MainActor
final class QuipModel: ObservableObject {
    @Published var text = ""
    @Published var side: QuipSide = .right
    /// Inserting and removing the bubble plays its pop-in and fade-out.
    @Published var isShown = false
}

/// The quip's host content: the bubble against its tail side, popping in and fading out.
/// It never takes clicks; the panel lets them through.
struct QuipView: View {
    @ObservedObject var model: QuipModel
    var surface: SurfaceStyle = .live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        glassContainer {
            if model.isShown {
                QuipBubble(text: model.text, side: model.side)
                    .modifier(MaterializeGlass(enabled: surface == .live))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: tailAnchor).combined(with: .opacity))
            }
        }
        .padding(.horizontal, QuipMetrics.margin.width)
        .padding(.vertical, QuipMetrics.margin.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.side == .right ? .leading : .trailing)
        .allowsHitTesting(false)
        .environment(\.surfaceStyle, surface)
    }

    /// The tail's tip, so the bubble grows out of it.
    private var tailAnchor: UnitPoint { model.side == .right ? .bottomLeading : .bottomTrailing }

    /// Liquid Glass animates in and out only inside a container.
    @ViewBuilder
    private func glassContainer(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26.0, *), surface == .live {
            GlassEffectContainer(content: content)
        } else {
            content()
        }
    }
}

/// Liquid Glass materializes in and out with the bubble, instead of going flat while it fades.
private struct MaterializeGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            content.glassEffectTransition(.materialize)
        } else {
            content
        }
    }
}

/// One line in a speech balloon whose tail points back at the pet.
struct QuipBubble: View {
    let text: String
    /// The side of the pet the bubble is on; the tail is on the opposite edge.
    let side: QuipSide

    var body: some View {
        let tail: QuipShape.Tail = side == .right ? .leading : .trailing
        Text(text)
            .font(QuipMetrics.font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: QuipMetrics.maxTextWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .padding(tail == .leading ? .leading : .trailing, QuipShape.tailLength)
            .fixedSize()
            .surface(in: QuipShape(tail: tail))
    }
}

/// A capsule with a comic speech tail that sweeps out of the lower part of its leading or trailing end.
struct QuipShape: Shape {
    enum Tail {
        case leading, trailing
    }

    /// How far the tail's tip reaches past the capsule.
    static let tailLength: CGFloat = 6

    var tail: Tail

    func path(in rect: CGRect) -> Path {
        let length = Self.tailLength
        var body = rect
        body.size.width -= length
        if tail == .leading { body.origin.x += length }
        let radius = body.height / 2
        let edge = tail == .leading ? body.minX : body.maxX
        let outward: CGFloat = tail == .leading ? -1 : 1
        /// `out` runs from the capsule's end towards the tip (negative is inside); `y` from the top.
        func point(_ out: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: edge + outward * out, y: body.minY + y)
        }

        // The upper side curves down to a soft tip level with the bottom; the lower side runs back
        // along the bottom edge. Both ends start inside the capsule so the shapes merge cleanly.
        let h = body.height
        var tailPath = Path()
        tailPath.move(to: point(-3, h * 0.42))
        tailPath.addCurve(to: point(length - 0.6, h - 1.2), control1: point(-0.5, h * 0.7), control2: point(length * 0.45, h - 1.5))
        tailPath.addQuadCurve(to: point(length - 2.4, h), control: point(length + 0.2, h - 0.1))
        tailPath.addCurve(to: point(-radius * 0.9, h), control1: point(length * 0.2, h + 0.2), control2: point(-radius * 0.4, h))
        tailPath.closeSubpath()
        return Path(roundedRect: body, cornerRadius: radius, style: .continuous).union(tailPath)
    }
}
