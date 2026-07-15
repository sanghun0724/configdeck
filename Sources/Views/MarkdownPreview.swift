import SwiftUI

/// Read-only rendered view of a markdown body. Block-level parsing (headings,
/// lists, quotes, fenced code, rules) with inline markdown via AttributedString.
/// Deliberately small — covers the constructs that appear in skill/agent files.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarkdownTheme.paragraphSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, MarkdownTheme.editorInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }
}

/// One rendered block. `view` is the SwiftUI rendering.
struct MarkdownBlock {
    enum Kind {
        case heading(level: Int, text: String)
        case bullet(items: [String])
        case ordered(items: [String])
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
    }
    let kind: Kind

    @ViewBuilder var view: some View {
        switch kind {
        case let .heading(level, t):
            Text(inline(t))
                .font(.system(size: MarkdownTheme.headingSize(level), weight: .bold))
        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item))
                    }
                }
            }
            .font(.system(size: MarkdownTheme.bodySize))
        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(item))
                    }
                }
            }
            .font(.system(size: MarkdownTheme.bodySize))
        case let .quote(t):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary).frame(width: 3)
                Text(inline(t)).foregroundStyle(.secondary)
            }
            .font(.system(size: MarkdownTheme.bodySize))
        case let .code(t):
            Text(t)
                .font(.system(size: MarkdownTheme.codeSize, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case let .paragraph(t):
            Text(inline(t))
                .font(.system(size: MarkdownTheme.bodySize))
                .lineSpacing(MarkdownTheme.lineSpacing)
        }
    }

    /// Inline markdown (bold/italic/code/links). Falls back to plain on parse failure.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// Line-oriented block parser.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flushBullets(_ buf: inout [String]) {
            if !buf.isEmpty { blocks.append(.init(kind: .bullet(items: buf))); buf = [] }
        }
        func flushOrdered(_ buf: inout [String]) {
            if !buf.isEmpty { blocks.append(.init(kind: .ordered(items: buf))); buf = [] }
        }

        var bullets: [String] = []
        var ordered: [String] = []

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // fenced code
            if trimmed.hasPrefix("```") {
                flushBullets(&bullets); flushOrdered(&ordered)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.init(kind: .code(code.joined(separator: "\n"))))
                i += 1   // skip closing fence
                continue
            }

            // heading
            if let level = headingLevel(trimmed) {
                flushBullets(&bullets); flushOrdered(&ordered)
                let body = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.init(kind: .heading(level: level, text: body)))
                i += 1; continue
            }

            // horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushBullets(&bullets); flushOrdered(&ordered)
                blocks.append(.init(kind: .rule))
                i += 1; continue
            }

            // bullet
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushOrdered(&ordered)
                bullets.append(String(trimmed.dropFirst(2)))
                i += 1; continue
            }

            // ordered
            if let item = orderedItem(trimmed) {
                flushBullets(&bullets)
                ordered.append(item)
                i += 1; continue
            }

            // quote
            if trimmed.hasPrefix(">") {
                flushBullets(&bullets); flushOrdered(&ordered)
                blocks.append(.init(kind: .quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))))
                i += 1; continue
            }

            // blank line
            if trimmed.isEmpty {
                flushBullets(&bullets); flushOrdered(&ordered)
                i += 1; continue
            }

            // paragraph (gather consecutive non-empty, non-special lines)
            flushBullets(&bullets); flushOrdered(&ordered)
            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || headingLevel(t) != nil || t.hasPrefix("```")
                    || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix(">")
                    || orderedItem(t) != nil || t == "---" { break }
                para.append(t); i += 1
            }
            blocks.append(.init(kind: .paragraph(para.joined(separator: " "))))
        }
        flushBullets(&bullets); flushOrdered(&ordered)
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func orderedItem(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: "."), s[..<dot].allSatisfy(\.isNumber), !s[..<dot].isEmpty else { return nil }
        let after = s.index(after: dot)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return String(s[s.index(after: after)...])
    }
}
