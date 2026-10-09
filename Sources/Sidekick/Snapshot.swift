import AppKit
import PetKit
import SidekickCore
import SwiftUI

/// `--snapshot <dir>`: renders the tray (also with a bubble hovered), the chat panel, the pet with its tray, a talking pet's
/// quip, and every installed pet's rows to PNGs offscreen, in light and dark, using demo data.
/// No window is shown.
@MainActor
enum Snapshot {
    static func render(to directory: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = ThreadStore(providers: DemoProvider.all(), persist: false)
            await store.refresh()
            let threads = store.threads
            guard let chatThread = threads.first else { return false }
            let messages = await store.messages(for: chatThread, limit: ChatModel.messageLimit)

            let roots = AppController.petRoots
            let pets = AppController.loadPets()
            let sprite = AppController.sprite(for: AppController.pet(in: pets, preferred: nil))
            let talker = pets.first { $0.quips?.working != nil }
            print("pet roots: \(roots.map(\.path).joined(separator: ", "))")
            print("pets: \(pets.isEmpty ? "none, using the placeholder" : pets.map(\.id).joined(separator: ", "))")

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let appearance = NSAppearance(named: appearance) else { continue }
                try await write(trayView(threads), appearance: appearance, to: directory, "tray-\(name).png")
                // The pointer on a bubble whose subtitle runs long, so its Open button shows and the line ends short.
                let hovered = threads.first { $0.status == .ready } ?? chatThread
                try await write(trayView(threads, hovered: hovered.id),
                                appearance: appearance, to: directory, "tray-hover-\(name).png")
                try await write(chatView(chatThread, messages: messages, store: store),
                                appearance: appearance, to: directory, "chat-\(name).png")
                try await write(overlayView(threads, sprite: sprite, collapsed: false),
                                appearance: appearance, to: directory, "overlay-\(name).png")
                try await write(overlayView(threads, sprite: sprite, collapsed: true),
                                appearance: appearance, to: directory, "overlay-collapsed-\(name).png")
                if let talker, let line = talker.quips?.working {
                    let sprite = PetSprite(pack: talker)
                    try await write(overlayView(threads, sprite: sprite, collapsed: true, quip: line),
                                    appearance: appearance, to: directory, "overlay-quip-\(name).png")
                    try await write(overlayView(threads, sprite: sprite, collapsed: false, quip: line),
                                    appearance: appearance, to: directory, "overlay-quip-expanded-\(name).png")
                }
            }
            if pets.isEmpty {
                try await write(petSheet(name: "Placeholder", id: "placeholder", sprite: sprite),
                                appearance: NSAppearance(named: .aqua), to: directory, "pet-placeholder.png")
            }
            for pack in pets {
                try await write(petSheet(name: pack.displayName, id: pack.id, sprite: PetSprite(pack: pack)),
                                appearance: NSAppearance(named: .aqua), to: directory, "pet-\(pack.id).png")
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return false
        }
    }

    // MARK: scenes

    /// Every bubble, expanded, with the tail towards a pet below, and the pointer on `hovered`.
    private static func trayView(_ threads: [AgentThread], hovered: String? = nil) -> NSView {
        let model = TrayModel()
        model.threads = threads
        model.hoveredId = hovered
        model.placement = .above
        model.tailX = PetSize.medium.points.width / 2
        let height = TrayMetrics.contentHeight(rows: threads.count)
        let size = CGSize(width: TrayMetrics.bubbleWidth + 2 * TrayMetrics.margin.width, height: height)
        return hosting(
            ZStack {
                SnapshotWallpaper()
                TrayView(model: model, surface: .snapshot).frame(width: size.width, height: size.height)
            },
            size: CGSize(width: size.width + 40, height: size.height + 40))
    }

    private static func chatView(_ thread: AgentThread, messages: [ChatMessage], store: ThreadStore) -> NSView {
        let model = ChatModel(thread: thread, store: store)
        // The longest send reason, to check that it wraps under the composer.
        model.preload(
            messages: messages, outcome: .copiedToClipboard("Slash commands can't be sent from Sidekick — copied instead"))
        let size = CGSize(width: ChatView.size.width + 80, height: ChatView.size.height + 80)
        return hosting(ZStack { SnapshotWallpaper(); ChatView(model: model, surface: .snapshot) }, size: size)
    }

    /// The pet panel's own content view, laid out bottom-left on a wallpaper-sized "screen".
    /// Collapsed, the tray hides and the pet wears the attention badge. With a `quip`, the pet has
    /// just started working and says it.
    private static func overlayView(
        _ threads: [AgentThread], sprite: PetSprite, collapsed: Bool, quip: String? = nil
    ) -> NSView {
        let screen = CGRect(x: 0, y: 0, width: collapsed ? (quip == nil ? 240 : 320) : 560, height: collapsed ? 200 : 500)
        let pet = CGRect(origin: PetPosition.defaultOrigin(in: screen), size: PetSize.medium.points)
        let badgeCount = collapsed ? threads.filter(\.status.wantsAttention).count : 0

        let overlay = PetOverlayView(sprite: sprite, surface: .snapshot)
        overlay.spriteView.setMood(quip == nil ? PetMood(threads.first?.status) : .running)
        let request = quip.map { line in
            QuipRequest(
                size: QuipMetrics.size(for: line), margin: QuipMetrics.margin, head: overlay.restingArtUnitFrame,
                avoiding: overlay.badgeFrame(count: badgeCount, pet: pet).map { [$0] } ?? [])
        }
        let layout = PetOverlayLayout(
            pet: pet, art: sprite.trayAnchor,
            tray: collapsed ? nil : TrayMetrics.preferredSize(rows: threads.count),
            margin: TrayMetrics.margin, gap: TrayMetrics.gap, screen: screen, petPadding: TrayMetrics.petPadding,
            quip: request)
        if let quip {
            overlay.quipModel.text = quip
            overlay.quipModel.isShown = true
        }
        overlay.apply(layout, threads: threads, badgeCount: badgeCount)
        overlay.frame = layout.panelFrame

        let canvas = NSView(frame: screen)
        let wallpaper = NSHostingView(rootView: SnapshotWallpaper())
        wallpaper.frame = screen
        canvas.addSubview(wallpaper)
        canvas.addSubview(overlay)
        return canvas
    }

    /// Frame 0 of every row, labelled.
    private static func petSheet(name: String, id: String, sprite: PetSprite) -> NSView {
        let cell = PetSize.medium.points
        let sheet = VStack(alignment: .leading, spacing: 10) {
            Text("\(name)  ·  \(id)").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(PetRow.allCases, id: \.rawValue) { row in
                    VStack(spacing: 4) {
                        Group {
                            if let image = sprite.frameImage(row: row, frame: 0) {
                                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: cell.width, height: cell.height)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        Text(row.name).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        let size = CGSize(width: 16 * 2 + 9 * cell.width + 8 * 8, height: 16 * 2 + 20 + 10 + cell.height + 18)
        return hosting(sheet, size: size)
    }

    // MARK: rendering

    private static func hosting(_ view: some View, size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    private static func write(
        _ view: NSView, appearance: NSAppearance?, to directory: URL, _ name: String
    ) async throws {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (scroll anchors, preferences) before capturing.
        try await Task.sleep(nanoseconds: 250_000_000)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        print("wrote \(url.path)")
    }
}

/// A soft, neutral desktop-like backdrop for snapshots.
private struct SnapshotWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(nsColor: NSColor(hex: 0x1C2230)), Color(nsColor: NSColor(hex: 0x2A3140))]
                    : [Color(nsColor: NSColor(hex: 0xDCE4EE)), Color(nsColor: NSColor(hex: 0xC5D0DD))],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color(nsColor: NSColor(hex: dark ? 0x3A4F70 : 0xA9C2E0)).opacity(0.7), .clear],
                center: UnitPoint(x: 0.8, y: 0.2), startRadius: 0, endRadius: 320)
            RadialGradient(
                colors: [Color(nsColor: NSColor(hex: dark ? 0x4B3A55 : 0xEBD5C8)).opacity(0.7), .clear],
                center: UnitPoint(x: 0.15, y: 0.85), startRadius: 0, endRadius: 300)
        }
    }
}
