import AppKit
import BridgeKit
import CoreImage.CIFilterBuiltins
import PetKit
import Security
import SidekickCore
import SwiftUI

/// Serves the phone page while the user has it switched on: on 127.0.0.1 only, with Tailscale's
/// HTTPS (`tailscale serve`) as the one way in from the phone. The pairing key lives in `phone.key`
/// (0600) and survives restarts, so a home-screen shortcut keeps working until the user makes a new link.
@MainActor
final class PhoneAccessController: ObservableObject {
    static let preferredPort: UInt16 = 47863

    @Published private(set) var isOn = false
    @Published private(set) var error: String?
    /// This Mac on the user's tailnet, when Tailscale is installed and connected.
    @Published private(set) var tailscale: Tailscale.Status?
    @Published private(set) var tailscaleNote: String?
    /// Called when the user switches access on or off, to remember it across launches.
    var onToggle: (Bool) -> Void = { _ in }

    private let api: SidekickAPI
    let push: PushCenter
    private var server: PhoneServer?
    private var key: String
    private var pet: PetPack?
    private var window: NSWindow?

    init(api: SidekickAPI, push: PushCenter) {
        self.api = api
        self.push = push
        key = Self.loadKey() ?? Self.newKey()
    }

    func setPet(_ pack: PetPack?) {
        pet = pack
        server?.update(assets: assets())
    }

    func setOn(_ on: Bool) {
        on ? start() : stop()
        onToggle(isOn)
    }

    /// Replace the key: every existing link and home-screen shortcut stops working.
    func resetLink() {
        key = Self.newKey()
        if isOn {
            stop()
            start()
        }
    }

    private func start() {
        guard server == nil else { return }
        let server = PhoneServer(api: api, key: key, port: Self.preferredPort, push: push)
        server.update(assets: assets())
        do {
            try server.start()
        } catch PhoneServer.StartError.portInUse(let port) {
            error = "Port \(port) is taken by another app. Quit it, then switch this on again."
            return
        } catch {
            self.error = "Couldn't start: \(error)"
            return
        }
        self.server = server
        error = nil
        isOn = true
        Task { await refreshTailscale() }
    }

    /// Tailscale is connected but isn't serving Sidekick over HTTPS yet.
    var needsHTTPS: Bool {
        guard isOn, let tailscale else { return false }
        return !tailscale.serving(port: Self.preferredPort)
    }

    /// `https://<mac>.<tailnet>.ts.net/p/<key>/`, once Tailscale serves Sidekick over HTTPS.
    var url: URL? {
        guard isOn, let tailscale, tailscale.serving(port: Self.preferredPort) else { return nil }
        return URL(string: "https://\(tailscale.host)/p/\(key)/")
    }

    func refreshTailscale() async {
        let status = await Tailscale.status()
        tailscale = status
        if status == nil {
            tailscaleNote = Tailscale.cli == nil
                ? "Install Tailscale on this Mac and your phone, and sign both into the same account."
                : "Tailscale is installed but not connected. Open it and sign in."
        } else {
            tailscaleNote = nil
        }
    }

    /// Ask Tailscale to serve Sidekick at https://<mac>.<tailnet>.ts.net (tailnet only, never public).
    func enableHTTPS() async {
        guard isOn else { return }
        tailscaleNote = "Turning on HTTPS…"
        if let problem = await Tailscale.serve(port: Self.preferredPort) {
            tailscaleNote = problem
        } else {
            tailscaleNote = nil
        }
        await refreshTailscale()
    }

    private func stop() {
        server?.stop()
        server = nil
        isOn = false
    }

    // MARK: window

    func showWindow() {
        Task { await refreshTailscale() }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Phone Access"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PhoneAccessView(controller: self))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: assets

    private func assets() -> PhoneAssets {
        let html = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Phone")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("Sidekick".utf8)
        let serviceWorker = Bundle.module.url(forResource: "sw", withExtension: "js", subdirectory: "Phone")
            .flatMap { try? Data(contentsOf: $0) } ?? Data()
        var badges: [String: Data] = [:]
        for platform in Platform.allCases {
            if let image = PlatformIcon.icon(for: platform)?.image, let png = Self.png(image, side: 72) {
                badges[platform.rawValue] = png
            }
        }
        return PhoneAssets(
            html: html,
            serviceWorker: serviceWorker,
            appIcon: Bundle.module.url(forResource: "icon", withExtension: "png", subdirectory: "Phone")
                .flatMap { try? Data(contentsOf: $0) },
            petSheet: pet.flatMap { Self.png($0.atlas) },
            petId: pet?.id ?? "none",
            petName: pet?.displayName ?? "Sidekick",
            badges: badges,
            macName: Host.current().localizedName ?? "your Mac")
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: key

    private static var keyFile: URL { Paths.appSupport.appendingPathComponent("phone.key") }

    private static func loadKey() -> String? {
        guard let text = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 20 ? key : nil
    }

    private static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        FileManager.default.createFile(
            atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        return key
    }
}

/// The Phone Access window: a switch, then either the Tailscale setup steps or the pairing QR code.
private struct PhoneAccessView: View {
    @ObservedObject var controller: PhoneAccessController
    @State private var copied: URL?

    var body: some View {
        VStack(spacing: 14) {
            Toggle(isOn: Binding(get: { controller.isOn }, set: { controller.setOn($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let my phone connect").font(.system(size: 13, weight: .semibold))
                    Text("From anywhere, through Tailscale. Never over Wi-Fi.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let error = controller.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let url = controller.url {
                paired(url)
            } else if controller.isOn {
                setup
            } else {
                Text("Your phone gets the same bubbles and chat as the pet, as a home-screen app.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380)
        .frame(minHeight: 160)
    }

    private func paired(_ url: URL) -> some View {
        VStack(spacing: 14) {
            if let qr = qrImage(url.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
            }
            Text("Scan with your iPhone's camera, then tap Share → Add to Home Screen.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            link("Your link", url)
            HStack {
                Spacer()
                Button("New link") {
                    copied = nil
                    controller.resetLink()
                }
                .help("Stops every phone that has the old link")
            }
            Text("Anyone on your tailnet who has this link can send to your threads. Make a new link if it gets out.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What's left before the phone can connect.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(done: controller.tailscale != nil, "Tailscale on this Mac, signed in")
            step(done: nil, "Tailscale on your iPhone, same account")
            step(done: nil, "HTTPS certificates on for your tailnet (login.tailscale.com/admin/dns)")
            step(done: controller.needsHTTPS ? false : nil, "Sidekick served over HTTPS on your tailnet")
            if let note = controller.tailscaleNote {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Check again") { Task { await controller.refreshTailscale() } }
                Spacer()
                Button("Turn on HTTPS") { Task { await controller.enableHTTPS() } }
                    .disabled(!controller.needsHTTPS)
                    .help("Runs tailscale serve: HTTPS on your tailnet only, never public")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A checklist line; `done` nil means Sidekick can't tell from here.
    private func step(done: Bool?, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done == true ? Color.green : Color.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ label: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(copied == url ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = url
                }
                .controlSize(.small)
            }
            Text(url.absoluteString)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The bits of the Tailscale CLI Sidekick needs: this Mac's tailnet name and `tailscale serve`.
enum Tailscale {
    struct Status: Equatable {
        /// MagicDNS name, e.g. `mac.tail1234.ts.net`.
        let host: String
        /// Local ports that `tailscale serve` proxies HTTPS to.
        let servedPorts: Set<Int>

        func serving(port: UInt16) -> Bool { servedPorts.contains(Int(port)) }
    }

    /// The CLI: the app bundle's own binary works as the command-line tool.
    static var cli: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Nil when Tailscale isn't installed, isn't running, or has no MagicDNS name.
    static func status() async -> Status? {
        guard let cli else { return nil }
        let result = await Shell.run(cli, ["status", "--json"], timeout: 5)
        guard result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              json["BackendState"] as? String == "Running",
              let me = json["Self"] as? [String: Any],
              var host = me["DNSName"] as? String, !host.isEmpty
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return Status(host: host, servedPorts: await servedPorts(cli))
    }

    /// Ports behind `tailscale serve` HTTPS handlers, read from its status JSON
    /// (Web → "<host>:443" → Handlers → "/" → Proxy "http://127.0.0.1:<port>").
    private static func servedPorts(_ cli: String) async -> Set<Int> {
        let result = await Shell.run(cli, ["serve", "status", "--json"], timeout: 5)
        guard result.ok, let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let web = json["Web"] as? [String: Any]
        else { return [] }
        var ports = Set<Int>()
        for case let site as [String: Any] in web.values {
            for case let handler as [String: Any] in (site["Handlers"] as? [String: Any] ?? [:]).values {
                if let proxy = handler["Proxy"] as? String, let port = URLComponents(string: proxy)?.port {
                    ports.insert(port)
                }
            }
        }
        return ports
    }

    /// Serve `http://127.0.0.1:<port>` over HTTPS on the tailnet. Returns a readable problem, or nil.
    static func serve(port: UInt16) async -> String? {
        guard let cli else { return "Tailscale isn't installed." }
        let result = await Shell.run(cli, ["serve", "--bg", "http://127.0.0.1:\(port)"], timeout: 20)
        if result.ok { return nil }
        let output = (result.stderr + result.stdout).lowercased()
        if output.contains("https") && (output.contains("not enabled") || output.contains("enable")) {
            return "Turn on HTTPS certificates for your tailnet first: login.tailscale.com/admin/dns, then try again."
        }
        let line = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .split(separator: "\n").first.map(String.init) ?? "tailscale serve failed"
        return line
    }
}

/// Turns thread status changes into phone notifications: a thread that starts needing the user,
/// finishes, or fails. The first look at the threads only sets the baseline, so launching
/// Sidekick never replays old states, and the same news for a thread is sent at most once a minute.
@MainActor
final class PushNotifier {
    private let push: PushCenter
    private var last: [String: ThreadStatus] = [:]
    private var primed = false
    private var sentAt: [String: Date] = [:]

    init(push: PushCenter) {
        self.push = push
    }

    /// - Parameter sending: false while phone access is off; the baseline still follows along.
    func update(_ threads: [AgentThread], sending: Bool) {
        defer {
            last = Dictionary(threads.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            primed = true
        }
        guard primed, sending else { return }
        let now = Date()
        sentAt = sentAt.filter { now.timeIntervalSince($0.value) < 60 }
        for thread in threads {
            guard let before = last[thread.id], before != thread.status,
                  let notification = Self.notification(for: thread) else { continue }
            let key = "\(thread.id)|\(thread.status.rawValue)"
            guard sentAt[key] == nil else { continue }
            sentAt[key] = now
            let push = push
            Task { await push.send(notification) }
        }
    }

    static func notification(for thread: AgentThread) -> PushNotification? {
        let agent = thread.platform.displayName
        switch thread.status {
        case .needsInput:
            let what = thread.detail?.localizedCaseInsensitiveContains("permission") == true ? "permission" : "input"
            return PushNotification(title: thread.title, body: "\(agent) needs your \(what)", threadId: thread.id, urgent: true)
        case .ready:
            return PushNotification(title: thread.title, body: "\(agent) finished", threadId: thread.id, urgent: false)
        case .failed:
            return PushNotification(title: thread.title, body: "\(agent) failed", threadId: thread.id, urgent: false)
        case .running, .idle:
            return nil
        }
    }
}
