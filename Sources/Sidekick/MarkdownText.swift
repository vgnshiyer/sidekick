import SwiftUI

/// One block of an assistant reply. Inline syntax (bold, code spans, links) stays in the text
/// and is rendered by `AttributedString`.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    /// `marker` is "•" for bullets or the item's number, such as "2.".
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(String)
    case rule

    /// Splits `text` into blocks: fenced code, ATX headings, list items, quotes, rules and paragraphs.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var afterBlank = false
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { afterBlank = trimmed.isEmpty }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if let fence = fence(trimmed) {
                flush()
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(String(next.dropFirst(min(indent, next.prefix { $0 == " " }.count))))
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(heading))
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [unquoted(trimmed)]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
                    quote.append(unquoted(next))
                    lines.removeFirst()
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else if let (marker, rest) = listItem(trimmed) {
                flush()
                blocks.append(.listItem(marker: marker, text: rest, depth: min(indent / 2, 3)))
            } else if paragraph.isEmpty, case .listItem(let marker, let item, let depth)? = blocks.last,
                      indent >= 2 || !afterBlank {
                // An indented line, or a lazy one right under the item, continues the item.
                blocks[blocks.count - 1] = .listItem(
                    marker: marker, text: item + (afterBlank ? "\n\n" : "\n") + trimmed, depth: depth)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    /// The opening fence ("```" or "~~~", or longer) of a fenced code block.
    private static func fence(_ line: String) -> String? {
        for mark: Character in ["`", "~"] {
            let run = line.prefix { $0 == mark }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func unquoted(_ line: String) -> String {
        let rest = line.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    /// "- item", "* item", "+ item", "3. item" or "3) item".
    private static func listItem(_ line: String) -> (String, String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return ("•", line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else { return nil }
        return ("\(digits).", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

/// An assistant reply as plain chat Markdown: paragraphs, headings, lists with hanging indents,
/// quotes and code blocks. Inherits the surrounding font.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        blocks = MarkdownBlock.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let text):
            Text(Self.inline(text)).font(.system(size: 13, weight: .semibold))
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                Text(Self.inline(text)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(width: 2)
                }
        case .code(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
