import AppKit
import SidekickCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

extension NSColor {
    /// A color that follows the light or dark appearance it is drawn in.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    /// A color that follows the view's light or dark appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: .dynamic(light: light, dark: dark))
    }

    static let claudeOrange = Color(nsColor: NSColor(hex: 0xD97757))
    static let codexInk = Color(nsColor: NSColor(hex: 0x111111))
}

extension ThreadStatus {
    /// Dot and chip tint.
    var tint: Color { Color(nsColor: nsTint) }

    /// `tint` for AppKit and Core Animation.
    var nsTint: NSColor {
        switch self {
        case .needsInput: return .dynamic(light: NSColor(hex: 0xF2A100), dark: NSColor(hex: 0xFFB82E))
        case .failed: return .dynamic(light: NSColor(hex: 0xEB3B30), dark: NSColor(hex: 0xFF5F57))
        case .ready: return .dynamic(light: NSColor(hex: 0x2FB350), dark: NSColor(hex: 0x32D35C))
        case .running: return .dynamic(light: NSColor(hex: 0x0A7AFF), dark: NSColor(hex: 0x3D9BFF))
        case .idle: return .dynamic(light: NSColor(hex: 0x8E8E93), dark: NSColor(hex: 0x98989F))
        }
    }

    /// Chip label color, darker than the tint in light mode so it stays legible.
    var labelColor: Color {
        switch self {
        case .needsInput: return Color(light: NSColor(hex: 0x9A5B00), dark: NSColor(hex: 0xFFC65C))
        case .failed: return Color(light: NSColor(hex: 0xC4241B), dark: NSColor(hex: 0xFF7B73))
        case .ready: return Color(light: NSColor(hex: 0x1D7F37), dark: NSColor(hex: 0x4ADE73))
        case .running: return Color(light: NSColor(hex: 0x0A60CC), dark: NSColor(hex: 0x6CB4FF))
        case .idle: return .secondary
        }
    }
}

extension AgentThread {
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New session" : trimmed
    }

    /// One line under the title: the status detail and the latest line or activity.
    var bubbleSubtitle: String {
        let parts = [detail, subtitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return folderName ?? "\(platform.displayName) · \(surface.displayName)"
    }

    /// "folder · branch · surface" for the chat panel.
    var locationLine: String {
        [folderName, branch, surface.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Where Open jumps to, for the chat footer.
    var openTargetName: String {
        switch surface {
        case .terminal: return "Terminal"
        // Codex has no editor deep link; its IDE threads open in the Codex app.
        case .ide: return platform == .codex ? "Codex" : "Editor"
        case .desktop, .unknown: return platform.displayName
        }
    }
}

extension SendOutcome {
    /// The chip's short word; `message` carries the reason.
    var label: String {
        switch self {
        case .delivered: return "Sent"
        case .queued: return "Queued"
        case .copiedToClipboard: return "Copied"
        case .failed: return "Not sent"
        }
    }
}

// MARK: - Surfaces

/// How translucent surfaces render. Offscreen snapshots can't capture Liquid Glass or
/// behind-window blur, so they use a flat translucent stand-in instead.
enum SurfaceStyle {
    case live, snapshot
}

private struct SurfaceStyleKey: EnvironmentKey {
    static let defaultValue = SurfaceStyle.live
}

extension EnvironmentValues {
    var surfaceStyle: SurfaceStyle {
        get { self[SurfaceStyleKey.self] }
        set { self[SurfaceStyleKey.self] = newValue }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a vibrant material before.
    func surface<S: Shape>(in shape: S, interactive: Bool = false, highlighted: Bool = false) -> some View {
        modifier(SurfaceBackground(shape: shape, interactive: interactive, highlighted: highlighted))
    }
}

private struct SurfaceBackground<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let highlighted: Bool
    @Environment(\.surfaceStyle) private var style
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .live:
            if #available(macOS 26.0, *) {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            } else {
                // No SwiftUI shadow here: it would render the material offscreen and lose the blur.
                outlined(content.background(VisualEffectBackground(shape: shape)))
            }
        case .snapshot:
            outlined(content.background(
                shape.fill(scheme == .dark ? Color(white: 0.17).opacity(0.78) : Color(white: 0.985).opacity(0.80))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.10), radius: 7, y: 2)))
        }
    }

    private func outlined(_ view: some View) -> some View {
        view
            .overlay(shape.fill(Color.primary.opacity(highlighted ? 0.045 : 0)))
            .overlay(shape.stroke(scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.07), lineWidth: 0.5))
    }
}

/// A behind-window material in the shape of `shape`. It stays vibrant while the app is
/// inactive, which it always is, and takes its shape from `maskImage` as AppKit requires.
private struct VisualEffectBackground<S: Shape>: NSViewRepresentable {
    let shape: S

    func makeNSView(context: Context) -> ShapedEffectView {
        let view = ShapedEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: ShapedEffectView, context: Context) {
        view.outline = { shape.path(in: $0).cgPath }
    }
}

private final class ShapedEffectView: NSVisualEffectView {
    var outline: ((CGRect) -> CGPath)? {
        didSet { updateMask() }
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard let outline, bounds.width > 0, bounds.height > 0 else { return }
        let path = outline(CGRect(origin: .zero, size: bounds.size))
        // Flipped drawing matches SwiftUI's top-left origin.
        maskImage = NSImage(size: bounds.size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
    }
}

/// Hosting view that takes clicks in a panel that never becomes active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
