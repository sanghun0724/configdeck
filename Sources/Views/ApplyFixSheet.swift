import SwiftUI

/// "Apply with Claude" flow for an analyze suggestion: send the file plus the
/// finding to the CLI, preview the returned fix as a line diff, and only write
/// through WriteGuard once the user confirms. Claude never touches the disk
/// directly — the app does the guarded write, so backup/stale/atomic all hold.
struct ApplyFixSheet: View {
    let suggestion: CleanupSuggestion
    let path: String
    let service: ClaudeService
    var onApplied: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case failed(String)
        case noChange
        case preview(original: String, fixed: String, rows: [(line: LineDiff.Line?, gap: Int)])
        case applied
    }
    @State private var phase: Phase = .loading

    /// LCS diff is quadratic — beyond this the preview (and therefore apply) is refused.
    private static let maxDiffLines = 3000

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 680, height: 500)
        .background(Theme.surface)
        .task { await fetchFix() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "\(String(localized: "Apply fix")) · \((path as NSString).lastPathComponent)")
            Text(suggestion.title)
                .font(Theme.Typo.serifTitle)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: Theme.Space.md) {
                ProgressView().controlSize(.small)
                Text("Asking Claude for the fix…")
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.inkSecondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.error)
                .padding(Theme.Space.lg)
        case .noChange:
            Label("Claude found nothing to change.", systemImage: "checkmark.circle")
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.inkSecondary)
        case .applied:
            Label("Applied — backup created.", systemImage: "checkmark.circle.fill")
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.successInk)
        case .preview(_, _, let rows):
            diffView(rows)
        }
    }

    private func diffView(_ rows: [(line: LineDiff.Line?, gap: Int)]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let line = row.line {
                        diffRow(line)
                    } else {
                        Text("⋯ \(row.gap) unchanged lines")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
        .background(Theme.card)
    }

    private func diffRow(_ line: LineDiff.Line) -> some View {
        let (prefix, fg, bg): (String, Color, Color) = switch line.kind {
        case .same: (" ", Theme.inkSecondary, .clear)
        case .removed: ("−", Theme.error, Theme.error.opacity(0.08))
        case .added: ("+", Theme.successInk, Theme.successSoft)
        }
        return Text("\(prefix) \(line.text)")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(fg)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            if case .preview(_, _, let rows) = phase {
                let removed = rows.filter { $0.line?.kind == .removed }.count
                let added = rows.filter { $0.line?.kind == .added }.count
                Text("\(removed) removed · \(added) added")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            switch phase {
            case .preview(let original, let fixed, _):
                Button("Cancel") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                Button("Apply") { apply(original: original, fixed: fixed) }
                    .buttonStyle(PrimaryButtonStyle())
            case .loading:
                Button("Cancel") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
            default:
                Button("Close") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(Theme.Space.lg)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: - Fix fetch / apply

    private var resolvedURL: URL {
        URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    private func fetchFix() async {
        guard let data = try? Data(contentsOf: resolvedURL) else {
            phase = .failed(String(localized: "File not readable"))
            return
        }
        let original = String(decoding: data, as: UTF8.self)
        guard original.components(separatedBy: "\n").count <= Self.maxDiffLines else {
            phase = .failed(String(localized: "File too large to preview — edit it manually instead."))
            return
        }
        let prompt = """
        You are fixing exactly one file in a Claude Code user configuration, following an audit finding.

        FINDING: \(suggestion.title)
        WHY: \(suggestion.rationale)

        FILE PATH: \(path)
        CURRENT CONTENT:
        \(original)

        Respond with ONLY the complete corrected file content — no prose, no markdown fences, \
        no explanations. Change only what the finding requires; preserve everything else exactly.
        """
        do {
            let reply = try await service.run(prompt: prompt)
            let fixed = Self.stripFences(reply.text)
            guard !fixed.isEmpty else {
                phase = .failed(String(localized: "The fix came back empty — nothing was changed."))
                return
            }
            guard fixed != original else {
                phase = .noChange
                return
            }
            guard fixed.components(separatedBy: "\n").count <= Self.maxDiffLines else {
                phase = .failed(String(localized: "File too large to preview — edit it manually instead."))
                return
            }
            phase = .preview(original: original, fixed: fixed,
                             rows: LineDiff.collapse(LineDiff.diff(original, fixed)))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(original: String, fixed: String) {
        // Same containment rule as delete: never write outside ~/.claude on the model's say-so.
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude").resolvingSymlinksInPath().path
        guard resolvedURL.path.hasPrefix(claudeDir + "/") else {
            phase = .failed(String(localized: "Refusing to edit a path outside ~/.claude"))
            return
        }
        let guardian = WriteGuard(
            fileURL: resolvedURL,
            backupDir: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude").appending(path: "backups"))
        do {
            // expectedHash pins the content we sent to Claude — if the file changed
            // underneath while waiting for the fix, the stale-guard rejects the write.
            try guardian.commit(Data(fixed.utf8), expectedHash: WriteGuard.hash(Data(original.utf8)))
            phase = .applied
            onApplied()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The prompt forbids fences, but strip them anyway if the model adds some.
    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            s = lines.joined(separator: "\n")
        }
        return s
    }
}
