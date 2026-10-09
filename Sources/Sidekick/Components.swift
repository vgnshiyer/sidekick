import AppKit
import SidekickCore
import SwiftUI

/// The platform's logo, read from the installed app: Claude's orange star, Codex's cloud. A drawn
/// mark when the app isn't there.
struct PlatformBadge: View {
    let platform: Platform
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon = PlatformIcon.icon(for: platform) {
                AppIconImage(icon: icon, size: size)
            } else {
                DrawnBadge(platform: platform, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(platform.displayName)
    }
}

/// A logo loaded at runtime from the user's installed app, never bundled: the artwork is the
/// apps' own. Loaded once per platform.
@MainActor
struct PlatformIcon {
    let image: NSImage
    /// How far the image spills past the badge on each side, as a share of its width: an app
    /// icon's transparent margin, or the tips of the star's rays.
    let margin: CGFloat

    /// A finished macOS icon: a rounded tile inside the standard margin.
    private static let appIconMargin: CGFloat = 0.1
    /// The star is thin rays, lighter than the cloud at the same size: drawn a little larger so
    /// the two weigh the same.
    private static let starMargin: CGFloat = 0.04

    static func icon(for platform: Platform) -> PlatformIcon? {
        switch platform {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// Claude's star from its menu-bar icon; the app icon (the star on an orange tile) without one.
    private static let claude: PlatformIcon? = {
        guard let app = app(bundleId: "com.anthropic.claudefordesktop", path: "/Applications/Claude.app") else {
            return nil
        }
        if let star = star(in: app) { return PlatformIcon(image: star, margin: starMargin) }
        return PlatformIcon(image: NSWorkspace.shared.icon(forFile: app.path), margin: appIconMargin)
    }()

    /// The Codex desktop app ships as ChatGPT.app. Its own icon is the ChatGPT one; the Codex cloud is `app.icns`.
    private static let codex: PlatformIcon? = {
        guard let app = app(bundleId: "com.openai.codex", path: "/Applications/ChatGPT.app") else { return nil }
        if let image = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/app.icns")),
           let cloud = cutOut(image) {
            return PlatformIcon(image: cloud, margin: 0)
        }
        // ChatGPT.app's own icon is the ChatGPT logo, not Codex's: the drawn mark instead.
        guard app.lastPathComponent != "ChatGPT.app" else { return nil }
        return PlatformIcon(image: NSWorkspace.shared.icon(forFile: app.path), margin: appIconMargin)
    }()

    private static func app(bundleId: String, path: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return url }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Claude.app's menu-bar icon is the star alone, black on clear (a template image). Takes the
    /// sharpest copy, fills the star with Claude orange and crops to it.
    private static func star(in app: URL) -> NSImage? {
        let resources = app.appendingPathComponent("Contents/Resources")
        let template = ["@3x", "@2x", ""].lazy
            .compactMap { try? Data(contentsOf: resources.appendingPathComponent("TrayIconTemplate\($0).png")) }
            .compactMap { NSBitmapImageRep(data: $0)?.cgImage }
            .first
        guard let template,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: template.width, height: template.height, bitsPerComponent: 8,
                  bytesPerRow: template.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        let (width, height) = (template.width, template.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(template, in: bounds)
        // Orange wherever the star is, at the star's own alpha.
        context.setBlendMode(.sourceAtop)
        context.setFillColor(NSColor(.claudeOrange).cgColor)
        context.fill(bounds)

        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
            }
        }
        guard maxX >= minX, let star = context.makeImage() else { return nil }
        return square(star, x: minX...maxX, y: minY...maxY)
    }

    /// Codex's `app.icns` is the cloud on an opaque white square. Clears the white that reaches the
    /// edges, un-blending the cloud's soft rim and shadow from it, keeps the white inside the cloud
    /// (its prompt), and crops to the cloud.
    private static func cutOut(_ image: NSImage, side: Int = 256) -> NSImage? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        /// How close to white a pixel is: its darkest channel.
        func lightness(_ index: Int) -> UInt8 {
            min(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2])
        }
        func opaque(_ index: Int) -> Bool { pixels[index * 4 + 3] == 255 }
        /// Near-white, or already clear should the artwork ever come with a transparent margin.
        func backdrop(_ index: Int) -> Bool {
            opaque(index) ? lightness(index) >= 205 : pixels[index * 4 + 3] == 0
        }

        // Flood in from the edges through the backdrop; the cloud's outline stops it.
        var background = [Bool](repeating: false, count: side * side)
        var queue = (0..<side).flatMap { [$0, (side - 1) * side + $0, $0 * side, $0 * side + side - 1] }
        while let index = queue.popLast() {
            guard !background[index], backdrop(index) else { continue }
            background[index] = true
            let x = index % side, y = index / side
            if x > 0 { queue.append(index - 1) }
            if x < side - 1 { queue.append(index + 1) }
            if y > 0 { queue.append(index - side) }
            if y < side - 1 { queue.append(index + side) }
        }

        // Un-blend from white: the least alpha that explains each color (premultiplied), and the
        // cloud's bounds while at it.
        var minX = side, minY = side, maxX = -1, maxY = -1
        for index in 0..<side * side {
            if background[index] {
                guard opaque(index) else { continue }
                let white = lightness(index)
                for channel in 0..<3 { pixels[index * 4 + channel] -= white }
                pixels[index * 4 + 3] = 255 - white
            } else {
                let x = index % side, y = index / side
                (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
            }
        }
        guard maxX >= minX, let cleared = context.makeImage() else { return nil }
        return square(cleared, x: minX...maxX, y: minY...maxY)
    }

    /// A square of `image` around the artwork spanning `x` by `y` (pixels, from the top left),
    /// centered on it and kept inside the image.
    private static func square(_ image: CGImage, x: ClosedRange<Int>, y: ClosedRange<Int>) -> NSImage? {
        let length = max(x.count, y.count)
        func origin(_ span: ClosedRange<Int>, _ side: Int) -> Int {
            min(max((span.lowerBound + span.upperBound + 1 - length) / 2, 0), side - length)
        }
        let crop = CGRect(x: origin(x, image.width), y: origin(y, image.height), width: length, height: length)
        guard let artwork = image.cropping(to: crop) else { return nil }
        return NSImage(cgImage: artwork, size: NSSize(width: length, height: length))
    }
}

/// A logo whose visible artwork fills `size`.
private struct AppIconImage: View {
    let icon: PlatformIcon
    let size: CGFloat

    var body: some View {
        // Trim the margin: draw the image larger and let its margin spill past the frame.
        let full = size / (1 - 2 * icon.margin)
        Image(nsImage: icon.image)
            .resizable()
            .interpolation(.high)
            .frame(width: full, height: full)
    }
}

/// Round platform mark, for when the app isn't installed: a sparkle on Claude orange, a prompt on Codex ink.
private struct DrawnBadge: View {
    let platform: Platform
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().fill(platform == .claude ? Color.claudeOrange : Color.codexInk)
            glyph
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.095, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 0.5)
            if platform == .codex, scheme == .dark {
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
        }
        .frame(width: size, height: size)
    }

    private var glyph: AnyShape {
        platform == .claude ? AnyShape(SparkGlyph()) : AnyShape(PromptGlyph())
    }
}

/// Eight rays from the center.
private struct SparkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<4 {
            let angle = Double(index) * .pi / 4
            let dx = cos(angle) * radius, dy = sin(angle) * radius
            path.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            path.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return path
    }
}

/// A shell prompt: ">_".
private struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        path.move(to: point(0.02, 0.14))
        path.addLine(to: point(0.40, 0.48))
        path.addLine(to: point(0.02, 0.82))
        path.move(to: point(0.56, 0.86))
        path.addLine(to: point(1.0, 0.86))
        return path
    }
}

/// Colored dot plus status label in a tinted capsule.
/// Status as a single dot: amber needs you, red failed, green ready, blinking blue running, gray idle.
/// The word is in the tooltip and for VoiceOver.
struct StatusChip: View {
    let status: ThreadStatus
    var size: CGFloat = 9

    var body: some View {
        StatusDot(status: status)
            .frame(width: size, height: size)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .help(status.label)
            .accessibilityElement()
            .accessibilityLabel(status.label)
    }
}

private struct StatusDot: View {
    let status: ThreadStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceStyle) private var surfaceStyle

    var body: some View {
        if status == .running, !reduceMotion, surfaceStyle == .live {
            PulsingDot(color: status.nsTint)
        } else {
            Circle().fill(status.tint)
        }
    }
}

/// The Running dot's pulse. Core Animation runs it in the render server, so it costs the app
/// nothing per frame; a SwiftUI animation here kept several percent of a core busy, even hidden.
private struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> PulsingDotView {
        PulsingDotView()
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.color = color
    }
}

private final class PulsingDotView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = color.cgColor
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer, layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}

/// Fades a scroll view's top or bottom edge while content is hidden past it (macOS 15+).
struct ScrollEdgeFade: ViewModifier {
    var height: CGFloat
    @State private var hidden = HiddenEdges()

    private struct HiddenEdges: Equatable {
        var above = false
        var below = false
    }

    func body(content: Content) -> some View {
        tracking(content).mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: hidden.above ? height : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: hidden.below ? height : 0)
            }
        }
    }

    @ViewBuilder
    private func tracking(_ content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: HiddenEdges.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                return HiddenEdges(
                    above: top > 0.5,
                    below: top + geometry.containerSize.height < geometry.contentSize.height - 0.5)
            } action: { _, edges in
                hidden = edges
            }
        } else {
            content
        }
    }
}

/// A rounded rectangle with an optional speech tail on its top or bottom edge.
struct BubbleShape: Shape {
    enum Tail: Equatable {
        case none
        /// Tail on the top edge, centered at `x` from the leading edge.
        case top(x: CGFloat)
        case bottom(x: CGFloat)
    }

    static let tailSize = CGSize(width: 22, height: 9)

    var cornerRadius: CGFloat = 14
    var tail: Tail = .none

    func path(in rect: CGRect) -> Path {
        let h = Self.tailSize.height
        var body = rect
        let tailX: CGFloat, edge: CGFloat, direction: CGFloat
        switch tail {
        case .none:
            return Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        case .top(let x):
            body.origin.y += h
            body.size.height -= h
            (tailX, edge, direction) = (x, body.minY, -1)
        case .bottom(let x):
            body.size.height -= h
            (tailX, edge, direction) = (x, body.maxY, 1)
        }
        let half = Self.tailSize.width / 2
        let x = min(max(tailX, body.minX + cornerRadius + half), body.maxX - cornerRadius - half)
        /// `dy` runs from the bubble's edge (0) towards the tip (`h`).
        func point(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: x + dx, y: edge + direction * dy)
        }

        // Concave sides that meet in a softly rounded tip; the base dips 1 pt into the body.
        var tailPath = Path()
        tailPath.move(to: point(-half, -1))
        tailPath.addLine(to: point(-half, 0))
        tailPath.addCurve(to: point(-2.2, h - 1.2), control1: point(-half * 0.45, 0), control2: point(-4.5, h - 3.5))
        tailPath.addQuadCurve(to: point(2.2, h - 1.2), control: point(0, h + 0.6))
        tailPath.addCurve(to: point(half, 0), control1: point(4.5, h - 3.5), control2: point(half * 0.45, 0))
        tailPath.addLine(to: point(half, -1))
        tailPath.closeSubpath()
        return Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous).union(tailPath)
    }
}
