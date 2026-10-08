import PetKit
import SidekickCore
import SwiftUI

/// Sizes shared by the tray view and the panel layout.
enum TrayMetrics {
    static let bubbleWidth: CGFloat = 300
    static let rowHeight: CGFloat = 54
    static let spacing: CGFloat = 6
    /// Room around the bubbles for their shadows.
    static let margin = CGSize(width: 14, height: 12)
    /// Space between the pet's art and the tip of the tail.
    static let gap: CGFloat = 2
    /// Room around the pet for the attention badge that sits on its corner.
    static let petPadding: CGFloat = 14
    /// Rows fully visible before the tray scrolls.
    static let visibleRows = 4

    /// Height of the whole scroll content for `rows` bubbles, margins included.
    static func contentHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
            + BubbleShape.tailSize.height + 2 * margin.height
    }

    /// The tray's size for `rows` bubbles, capped at `visibleRows`; nil when empty. When capped, the
    /// far edge is the far bubble's own edge, so no clipped sliver or shadow shows until you scroll.
    static func preferredSize(rows: Int) -> CGSize? {
        guard rows > 0 else { return nil }
        let height = rows > visibleRows
            ? contentHeight(rows: visibleRows) - margin.height
            : contentHeight(rows: rows)
        return CGSize(width: bubbleWidth + 2 * margin.width, height: height)
    }
}

/// What the tray shows; owned by the pet panel.
@MainActor
final class TrayModel: ObservableObject {
    /// Most urgent first.
    @Published var threads: [AgentThread] = []
    @Published var placement: TrayPlacement = .above
    /// The pet's center, measured from the bubbles' leading edge.
    @Published var tailX: CGFloat = 48

    /// The bubble under the pointer, which shows its Open button. The pet panel's pointer
    /// tracking sets it, so it holds while the app is inactive and clears as the panel stops taking the mouse.
    @Published var hoveredId: String?

    /// Bubble frames in the tray's coordinates (origin top-left), for hit-testing and anchoring.
    var bubbleFrames: [String: CGRect] = [:]
    /// The bubbles moved (scrolled, re-sorted, added or removed), maybe under a still pointer.
    var onFramesChanged: () -> Void = {}
    var onSelect: (AgentThread) -> Void = { _ in }
    /// A bubble's Open button: jump to the thread in its own app, without the chat.
    var onOpen: (AgentThread) -> Void = { _ in }
}

struct TrayView: View {
    @ObservedObject var model: TrayModel
    var surface: SurfaceStyle = .live

    var body: some View {
        // The most urgent bubble sits nearest the pet.
        let ordered = model.placement == .above ? Array(model.threads.reversed()) : model.threads

        ScrollView(.vertical) {
            VStack(spacing: TrayMetrics.spacing) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, thread in
                    BubbleRow(
                        thread: thread, tail: tail(at: index, of: ordered.count),
                        hovering: model.hoveredId == thread.id,
                        select: { model.onSelect(thread) },
                        open: { model.onOpen(thread) })
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: BubbleFramesKey.self, value: [thread.id: geometry.frame(in: .named(Self.space))])
                    })
                }
            }
            .padding(.horizontal, TrayMetrics.margin.width)
            .padding(.vertical, TrayMetrics.margin.height)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(model.placement == .above ? .bottom : .top)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(BubbleFramesKey.self) { frames in
            MainActor.assumeIsolated {
                model.bubbleFrames = frames
                model.onFramesChanged()
            }
        }
        .environment(\.surfaceStyle, surface)
    }

    private static let space = "tray"

    private func tail(at index: Int, of count: Int) -> BubbleShape.Tail {
        let x = model.tailX
        switch model.placement {
        case .above: return index == count - 1 ? .bottom(x: x) : .none
        case .below: return index == 0 ? .top(x: x) : .none
        }
    }
}

/// One thread: badge, title, status chip and a subtitle line. On hover, an Open button sits at
/// the end of the subtitle line.
private struct BubbleRow: View {
    let thread: AgentThread
    let tail: BubbleShape.Tail
    let hovering: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        let shape = BubbleShape(cornerRadius: 14, tail: tail)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    PlatformBadge(platform: thread.platform)
                    Text(thread.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    StatusChip(status: thread.status)
                }
                Text(thread.bubbleSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Ends short of the Open button while it shows.
                    .padding(.trailing, hovering ? OpenButton.size + 6 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .anchorPreference(key: SubtitleBoundsKey.self, value: .bounds) { $0 }
            }
            .scrollFade()
            .padding(.horizontal, 11)
            .frame(width: TrayMetrics.bubbleWidth, height: TrayMetrics.rowHeight, alignment: .leading)
            .padding(.top, tail.isTop ? BubbleShape.tailSize.height : 0)
            .padding(.bottom, tail.isBottom ? BubbleShape.tailSize.height : 0)
            .contentShape(shape)
            .surface(in: shape, interactive: true, highlighted: hovering)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chat")
        .accessibilityAction(named: "Open in \(thread.openTargetName)", open)
        // A sibling of the row's button, not inside its label, where it would never get the click.
        .overlayPreferenceValue(SubtitleBoundsKey.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let line = geometry[anchor]
                    OpenButton(target: thread.openTargetName, action: open)
                        .scrollFade()
                        // A point low centers it on the text's ink and leaves a gap under the chip.
                        .position(x: line.maxX - OpenButton.size / 2, y: line.midY + 1)
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                        .allowsHitTesting(hovering)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// Small round button that opens the thread in its own app.
private struct OpenButton: View {
    /// Under the chat's buttons, so it keeps clear of the status chip above the subtitle line.
    static let size: CGFloat = 18

    let target: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(RoundButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help("Open in \(target)")
    }
}

/// A quiet filled circle, like the chat panel's buttons, that brightens under the pointer.
private struct RoundButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering || configuration.isPressed
        configuration.label
            .foregroundStyle(lit ? .primary : .secondary)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.12 : 0.07)))
    }
}

private extension View {
    /// Soft edges while scrolling: fade the content only, in step with how far it has left.
    /// Glass and materials must keep full opacity and no masks above them, or their backdrop breaks.
    func scrollFade() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content.opacity(1 - 0.9 * min(abs(phase.value), 1))
        }
    }
}

private struct SubtitleBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private extension BubbleShape.Tail {
    var isTop: Bool { if case .top = self { return true } else { return false } }
    var isBottom: Bool { if case .bottom = self { return true } else { return false } }
}

private struct BubbleFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
