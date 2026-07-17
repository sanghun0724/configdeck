import Foundation

/// One conversation turn parsed from a transcript line. `id` is the source line
/// index — unique within a single transcript, stable across re-parses.
struct SessionTurn: Identifiable {
    enum Kind {
        case user(text: String)
        case assistantText(markdown: String)
        case thinking(text: String)
        case toolUse(name: String, inputSummary: String)
        case toolResult(text: String, isError: Bool)
    }
    let id: Int
    let kind: Kind
    let timestamp: Date?
    let isSidechain: Bool
}

/// Read-only parsed view of one `~/.claude/projects/<dir>/<session>.jsonl` transcript.
struct SessionTranscript {
    var turns: [SessionTurn] = []
    /// Last `ai-title` event wins — Claude Code rewrites the title mid-session.
    var title: String?
    var cwd: String?
    var gitBranch: String?
    /// Last assistant model seen.
    var model: String?
    /// Malformed or unrecognized lines — surfaced in the UI so schema drift stays visible.
    var skippedLines = 0
}

/// Tolerant JSONL parser. The transcript schema is unofficial and drifts between
/// Claude Code versions, so parsing is allowlist-based: known types produce turns,
/// known noise types are ignored, anything else is counted and skipped — never a crash.
enum SessionTranscriptParser {
    /// Cap for a single text payload. Multi-MB transcripts carry their bytes in tool
    /// results and thinking blocks, so truncating here bounds memory without pagination.
    /// ponytail: full-file parse, ceiling ~15MB transcripts; add reverse-chunked loading past ~50MB
    static let maxBlockLength = 20_000

    /// Event types that carry no conversation content — ignored without counting,
    /// so `skippedLines` only reports genuine drift (unknown types, broken JSON).
    private static let noiseTypes: Set<String> = [
        "system", "last-prompt", "mode", "permission-mode",
        "file-history-snapshot", "file-history-delta", "attachment",
        "frame-link", "queue-operation", "summary", "agent-name",
    ]

    static func parse(_ raw: String) -> SessionTranscript {
        var transcript = SessionTranscript()
        var lineIndex = -1
        raw.enumerateLines { line, _ in
            lineIndex += 1
            guard !line.isEmpty else { return }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else {
                transcript.skippedLines += 1
                return
            }

            if transcript.cwd == nil, let cwd = object["cwd"] as? String { transcript.cwd = cwd }
            if transcript.gitBranch == nil, let branch = object["gitBranch"] as? String { transcript.gitBranch = branch }

            switch type {
            case "user":
                appendUserTurns(object, line: lineIndex, into: &transcript)
            case "assistant":
                appendAssistantTurns(object, line: lineIndex, into: &transcript)
            case "ai-title":
                if let title = object["aiTitle"] as? String, !title.isEmpty {
                    transcript.title = title
                }
            default:
                if !noiseTypes.contains(type) { transcript.skippedLines += 1 }
            }
        }
        return transcript
    }

    // MARK: - Event → turns

    private static func appendUserTurns(_ object: [String: Any], line: Int, into transcript: inout SessionTranscript) {
        guard let message = object["message"] as? [String: Any] else { return }
        let timestamp = date(object["timestamp"])
        let isSidechain = object["isSidechain"] as? Bool ?? false

        if let text = message["content"] as? String {
            transcript.turns.append(SessionTurn(
                id: line,
                kind: .user(text: truncated(text)),
                timestamp: timestamp,
                isSidechain: isSidechain
            ))
        } else if let blocks = message["content"] as? [[String: Any]] {
            // Tool results arrive as user events with a block array.
            for block in blocks where block["type"] as? String == "tool_result" {
                transcript.turns.append(SessionTurn(
                    id: line,
                    kind: .toolResult(
                        text: truncated(resultText(of: block)),
                        isError: block["is_error"] as? Bool ?? false
                    ),
                    timestamp: timestamp,
                    isSidechain: isSidechain
                ))
            }
        }
    }

    private static func appendAssistantTurns(_ object: [String: Any], line: Int, into transcript: inout SessionTranscript) {
        guard let message = object["message"] as? [String: Any] else { return }
        if let model = message["model"] as? String { transcript.model = model }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        let timestamp = date(object["timestamp"])
        let isSidechain = object["isSidechain"] as? Bool ?? false

        for block in blocks {
            let kind: SessionTurn.Kind?
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                kind = text.isEmpty ? nil : .assistantText(markdown: truncated(text))
            case "thinking":
                // Thinking payload lives under the "thinking" key (no "text" key).
                let text = block["thinking"] as? String ?? ""
                kind = text.isEmpty ? nil : .thinking(text: truncated(text))
            case "tool_use":
                kind = .toolUse(
                    name: block["name"] as? String ?? "tool",
                    inputSummary: inputSummary(of: block["input"] as? [String: Any] ?? [:])
                )
            default:
                kind = nil
            }
            if let kind {
                transcript.turns.append(SessionTurn(id: line, kind: kind, timestamp: timestamp, isSidechain: isSidechain))
            }
        }
    }

    // MARK: - Field extraction

    /// tool_result `content` is a plain string or an array of blocks; only text
    /// blocks carry readable output (tool_reference etc. are skipped).
    private static func resultText(of block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        guard let parts = block["content"] as? [[String: Any]] else { return "" }
        return parts
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    /// The most recognizable input field of a tool call, falling back to the
    /// serialized input. Kept whole (up to the block cap) — the collapsed row
    /// label takes its first line, the expanded view shows all of it.
    private static func inputSummary(of input: [String: Any]) -> String {
        let value = (input["command"] as? String)
            ?? (input["file_path"] as? String)
            ?? input.sorted(by: { $0.key < $1.key }).lazy.compactMap({ $0.value as? String }).first
            ?? (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) }
            ?? ""
        return truncated(value)
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxBlockLength else { return text }
        return String(text.prefix(maxBlockLength)) + "… (truncated)"
    }

    /// Transcript timestamps are ISO8601 with fractional seconds; the plain variant
    /// is kept as a fallback against format drift.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
