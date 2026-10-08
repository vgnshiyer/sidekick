import AppKit
import SidekickCore
import SwiftUI

/// State of the chat panel for one thread.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var thread: AgentThread
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var loaded = false
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published private(set) var outcome: SendOutcome?

    static let messageLimit = 20
    /// Long messages are cut here; Open shows the rest.
    static let maxMessageLength = 4000

    private let store: ThreadStore
    var onClose: () -> Void = {}
    /// The draft was delivered or queued.
    var onSent: () -> Void = {}
    /// The user jumped to the thread's own app.
    var onOpened: () -> Void = {}

    init(thread: AgentThread, store: ThreadStore) {
        self.thread = thread
        self.store = store
    }

    /// Follow store updates; reload messages when the thread moved on.
    func update(_ newThread: AgentThread) {
        let changed = newThread.updatedAt != thread.updatedAt || newThread.status != thread.status
        thread = newThread
        if changed { reload() }
    }

    func reload() {
        let thread = thread
        Task {
            messages = await store.messages(for: thread, limit: Self.messageLimit).map(Self.trimmed)
            loaded = true
        }
    }

    var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        guard canSend else { return }
        let text = draft
        sending = true
        outcome = nil
        Task {
            let result = await store.send(text, to: thread)
            sending = false
            outcome = result
            switch result {
            case .failed: return
            case .delivered, .queued: onSent()
            case .copiedToClipboard: break
            }
            draft = ""
            reload()
        }
    }

    /// Bring the thread's own app forward and get out of its way.
    func open() {
        let thread = thread
        Task { await store.open(thread) }
        onOpened()
        onClose()
    }

    /// Snapshot support: show fixed content without a store round trip.
    func preload(messages: [ChatMessage], outcome: SendOutcome?) {
        self.messages = messages.map(Self.trimmed)
        self.outcome = outcome
        loaded = true
    }

    private static func trimmed(_ message: ChatMessage) -> ChatMessage {
        guard message.text.count > maxMessageLength else { return message }
        var copy = message
        copy.text = String(message.text.prefix(maxMessageLength)) + "…"
        return copy
    }
}

struct ChatView: View {
    static let size = CGSize(width: 360, height: 440)
    /// Transparent margin the panel keeps around the chat for the glass's shadow.
    static let shadowPadding: CGFloat = 24

    @ObservedObject var model: ChatModel
    var surface: SurfaceStyle = .live

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            messageList
            Divider().opacity(0.6)
            composer
            if let outcome = model.outcome, outcome.message != outcome.label {
                Text(outcome.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .surface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.surfaceStyle, surface)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PlatformBadge(platform: model.thread.platform, size: 22)
                Text(model.thread.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusChip(status: model.thread.status)
                Button(action: model.onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
            Text(model.thread.locationLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 32)
                .padding(.trailing, 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    // MARK: messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(ScrollEdgeFade(height: 18))
            .onChange(of: model.messages.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .overlay {
                if model.loaded, model.messages.isEmpty {
                    Text("No messages yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerField(
                text: $model.draft,
                isEnabled: !model.sending,
                onSubmit: model.send,
                onCancel: model.onClose)
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("Reply to \(model.thread.displayTitle)…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)))
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var sendButton: some View {
        Button(action: model.send) {
            ZStack {
                Circle().fill(model.canSend ? Color.accentColor : Color.primary.opacity(0.12))
                if model.sending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.canSend ? Color.white : Color.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .help("Send (Return)")
        .accessibilityLabel("Send")
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: model.open) {
                Label("Open in \(model.thread.openTargetName)", systemImage: "arrow.up.forward")
            }
            .buttonStyle(CapsuleButtonStyle())
            Spacer(minLength: 8)
            if let outcome = model.outcome {
                OutcomeChip(outcome: outcome)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 11)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.accentColor.opacity(0.17)))
            }
        case .assistant:
            MarkdownText(message.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A quiet capsule button that matches the chips.
private struct CapsuleButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.065)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// Inline send feedback: Sent, Queued, Copied or Not sent. The full reason shows under the composer.
private struct OutcomeChip: View {
    let outcome: SendOutcome

    var body: some View {
        Label {
            Text(outcome.label).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.13)))
        .fixedSize()
    }

    private var symbol: String {
        switch outcome {
        case .delivered: return "checkmark"
        case .queued: return "clock"
        case .copiedToClipboard: return "doc.on.clipboard"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch outcome {
        case .delivered: return ThreadStatus.ready.labelColor
        case .queued: return ThreadStatus.running.labelColor
        case .copiedToClipboard: return .secondary
        case .failed: return ThreadStatus.failed.labelColor
        }
    }
}

/// Multi-line plain-text field: Return sends, Shift+Return (or Option/Control+Return) adds a newline, Esc cancels.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    static let maxLines: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel("Reply")

        let scrollView = ComposerScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.textView else { return }
        if textView.string != text { textView.string = text }
        textView.isEditable = isEnabled
        textView.textColor = isEnabled ? .labelColor : .secondaryLabelColor
    }

    /// Grows with the text up to `maxLines`, then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        // A trailing newline starts a line that boundingRect would not count.
        let measured = text.hasSuffix("\n") || text.isEmpty ? text + " " : text
        let bounds = (measured as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font])
        let height = min(max(lineHeight, ceil(bounds.height)), lineHeight * Self.maxLines)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField

        init(_ parent: ComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)) where NSApp.currentEvent?.modifierFlags.contains(.shift) != true:
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Scroll view around the composer's text view; focuses it when shown.
final class ComposerScrollView: NSScrollView {
    var textView: NSTextView? { documentView as? NSTextView }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let textView { window?.makeFirstResponder(textView) }
    }
}
