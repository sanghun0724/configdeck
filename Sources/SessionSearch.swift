import Foundation

/// One session with content matching a global search query.
struct SessionSearchHit: Identifiable {
    var id: String { path }
    let path: String
    /// Text around the first match, single-line.
    let snippet: String
    /// Matching lines in the transcript (allowlist-confirmed, not raw JSON hits).
    let matchCount: Int
}

/// Streaming full-content search over transcript files. Read-only, file-at-a-time
/// (largest observed file ~15MB, so whole-file reads are fine), cancellable at
/// file boundaries. A raw-line `contains` prefilter keeps JSON parsing off the
/// non-matching 99% of lines; matched lines are then checked against conversation
/// text fields only, so base64 signatures and JSON keys can't produce false hits.
struct SessionContentSearcher {
    func search(
        query: String,
        in files: [String],
        isCancelled: () -> Bool = { false },
        onProgress: (_ scanned: Int) -> Void = { _ in },
        onHit: (SessionSearchHit) -> Void
    ) {
        guard !query.isEmpty else { return }
        for (index, path) in files.enumerated() {
            if isCancelled() { return }
            if let hit = scanFile(path, query: query) { onHit(hit) }
            onProgress(index + 1)
        }
    }

    private func scanFile(_ path: String, query: String) -> SessionSearchHit? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var snippet: String?
        var matchCount = 0
        raw.enumerateLines { line, _ in
            guard line.range(of: query, options: .caseInsensitive) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            for text in Self.searchableTexts(of: object) {
                if let range = text.range(of: query, options: .caseInsensitive) {
                    matchCount += 1
                    if snippet == nil { snippet = Self.snippet(of: text, around: range) }
                    break
                }
            }
        }
        guard let snippet else { return nil }
        return SessionSearchHit(path: path, snippet: snippet, matchCount: matchCount)
    }

    /// Conversation text only: user prompts, assistant text/thinking, tool-result
    /// text blocks. Signatures, ids, tool names and inputs are deliberately excluded.
    static func searchableTexts(of object: [String: Any]) -> [String] {
        guard let type = object["type"] as? String,
              let message = object["message"] as? [String: Any] else { return [] }
        switch type {
        case "user":
            if let text = message["content"] as? String { return [text] }
            guard let blocks = message["content"] as? [[String: Any]] else { return [] }
            return blocks
                .filter { $0["type"] as? String == "tool_result" }
                .flatMap { block -> [String] in
                    if let text = block["content"] as? String { return [text] }
                    guard let parts = block["content"] as? [[String: Any]] else { return [] }
                    return parts
                        .filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }
                }
        case "assistant":
            guard let blocks = message["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                case "thinking": return block["thinking"] as? String
                default: return nil
                }
            }
        default:
            return []
        }
    }

    private static func snippet(of text: String, around range: Range<String.Index>, context: Int = 60) -> String {
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        var clipped = String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if start > text.startIndex { clipped = "…" + clipped }
        if end < text.endIndex { clipped += "…" }
        return clipped
    }
}
