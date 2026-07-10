import AppKit
import SwiftUI

/// Persistent state for `AssistantView` — owned by `AppShell` (like `SettingsStore`) so
/// analysis results and chat history survive switching away from the 분석 tab and back.
@MainActor
final class AssistantStore: ObservableObject {
    enum Mode: Hashable { case analyze, chat }

    let service = ClaudeService()
    @Published var mode: Mode = .analyze

    // Analyze
    @Published var running = false
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var error: String?
    @Published var hasRun = false
    @Published var duration: TimeInterval?

    // Chat
    @Published fileprivate var messages: [ChatMessage] = []
    @Published var sending = false
    @Published var sessionId: String?
}

/// Cleanup assistant. Bridges to the `claude` CLI to (1) analyze the scanned config and
/// propose cleanups, and (2) chat about it. Suggestions are review-first: the model never
/// touches files — the user reveals or deletes (delete goes through WriteGuard's backup).
struct AssistantView: View {
    let data: ConfigData
    @ObservedObject var assistant: AssistantStore
    var onChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if !assistant.service.isAvailable {
                    notFound
                } else if assistant.mode == .analyze {
                    AnalyzePane(assistant: assistant, data: data, inventory: inventory, onChange: onChange)
                } else {
                    ChatPane(assistant: assistant, inventory: inventory)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Text("Analyze")
                .font(Theme.Typo.serifTitle)
                .foregroundStyle(Theme.ink)
            Text("claude CLI")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            SegmentedControl(
                selection: $assistant.mode,
                options: [
                    (value: .analyze, label: String(localized: "Analyze")),
                    (value: .chat, label: String(localized: "Chat"))
                ]
            )
            .frame(width: 140)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(height: Theme.Dim.topBarHeight + 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var notFound: some View {
        ContentUnavailableView {
            Label("Claude CLI not found", systemImage: "terminal")
        } description: {
            Text("Looked in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin and ~/.claude/local. Install Claude Code or symlink `claude` into one of those.")
        }
    }

    /// Compact, bounded inventory of the scanned config fed to the model as context.
    private var inventory: String {
        var lines: [String] = ["# ~/.claude inventory", ""]
        lines.append("## Skills (\(data.skills.count))")
        lines += data.skills.map { "- \($0.name): \($0.description.prefix(120)) [\($0.path)]" }
        lines.append("\n## Agents (\(data.agents.count))")
        lines += data.agents.map { "- \($0.name)\($0.model.map { " (\($0))" } ?? ""): \($0.description.prefix(120)) [\($0.path)]" }
        lines.append("\n## Commands (\(data.commands.count))")
        lines += data.commands.map { "- \($0.name) [\($0.kind)] [\($0.path)]" }
        lines.append("\n## MCP servers (\(data.mcpServers.count))")
        lines += data.mcpServers.map { "- \($0.name) [\($0.kind)] \(Self.redactSecrets($0.detail).prefix(100))" }
        lines.append("\n## Hooks (\(data.hooks.count))")
        lines += data.hooks.map { "- \($0.event) matcher=\($0.matcher) → \($0.commands.joined(separator: "; ").prefix(120))" }
        lines.append("\n## Permissions")
        lines.append("allow: \(data.allow.map(\.value).joined(separator: ", "))")
        lines.append("ask: \(data.ask.map(\.value).joined(separator: ", "))")
        lines.append("deny: \(data.deny.map(\.value).joined(separator: ", "))")
        lines.append("\n## Env keys")
        lines.append(data.envVars.map(\.key).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    /// MCP stdio command lines sometimes inline a token (`--token ghp_xxx`, `--api-key=sk-xxx`).
    /// Redact the value following any token/key/secret/password-looking flag before this
    /// leaves the app (even locally, to the `claude` CLI process).
    private static func looksLikeSecretFlag(_ s: String) -> Bool {
        let name = s.drop { $0 == "-" }.lowercased()
        return ["apikey", "api-key", "api_key", "token", "secret", "password"].contains(name)
    }

    private static func redactSecrets(_ line: String) -> String {
        var result: [String] = []
        var redactNext = false
        for token in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if redactNext {
                result.append("[REDACTED]")
                redactNext = false
                continue
            }
            if let eq = token.firstIndex(of: "="), looksLikeSecretFlag(String(token[..<eq])) {
                result.append("\(token[..<eq])=[REDACTED]")
                continue
            }
            result.append(token)
            redactNext = looksLikeSecretFlag(token)
        }
        return result.joined(separator: " ")
    }
}

// MARK: - Analyze

private struct AnalyzePane: View {
    @ObservedObject var assistant: AssistantStore
    let data: ConfigData
    let inventory: String
    var onChange: () -> Void

    private var running: Bool { assistant.running }
    private var suggestions: [CleanupSuggestion] { assistant.suggestions }
    private var error: String? { assistant.error }
    private var hasRun: Bool { assistant.hasRun }
    private var duration: TimeInterval? { assistant.duration }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                commandBar
                    .padding(.bottom, 28)

                if let error {
                    errorCard(error)
                } else if hasRun && !running {
                    Kicker(text: "Claude")
                        .padding(.bottom, 12)
                    headline
                        .padding(.bottom, 8)
                    Text(countsLine)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.bottom, 30)
                    VStack(spacing: 12) {
                        ForEach(suggestions) { s in
                            SuggestionCard(suggestion: s, onChange: onChange)
                        }
                    }
                } else if !running {
                    Text("Sends your config inventory to the claude CLI to review overlapping skills, dead paths, and dormant items together.")
                        .font(Theme.Typo.serifBody)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineSpacing(6)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Command bar (design 2c: › claude analyze ~/.claude · 완료 · 다시 실행)

    private var commandBar: some View {
        HStack(spacing: 12) {
            Text("›")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.accentStrong)
            (Text("claude ").foregroundStyle(Theme.ink)
                + Text("analyze ~/.claude").foregroundStyle(Theme.inkTertiary))
                .font(.system(size: 13, design: .monospaced))
            Spacer(minLength: Theme.Space.sm)
            status
            Button(running ? "Running…" : (hasRun ? "Run again" : "Run")) {
                Task { await analyze() }
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(running)
            .help("Sends your config inventory to the claude CLI (model: sonnet)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var status: some View {
        if running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else if hasRun {
            HStack(spacing: 6) {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text(duration.map { String(localized: "Done · \(String(format: "%.1f", $0))s") } ?? String(localized: "Done"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.successInk)
            }
        }
    }

    // MARK: - Headline (serif voice)

    private var headline: some View {
        Group {
            if suggestions.isEmpty {
                Text("I went through your whole library, start to finish. Nothing to fix — it's in good shape.")
            } else {
                Text("I went through your whole library, start to finish. It's mostly in good shape, with ")
                    + Text("\(suggestions.count) spots").foregroundStyle(Theme.accentStrong)
                    + Text(" worth a look.")
            }
        }
        .font(.system(size: 21, design: .serif))
        .foregroundStyle(Theme.ink)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var countsLine: String {
        String(localized: "Read \(data.skills.count) skills · \(data.agents.count) agents · \(data.commands.count) commands · \(data.hooks.count) hooks · \(data.mcpServers.count) MCP servers.")
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("Analysis failed", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.error)
            Text(msg).font(Theme.Typo.caption).foregroundStyle(Theme.inkSecondary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func analyze() async {
        assistant.running = true; assistant.error = nil
        let started = Date()
        defer { assistant.running = false; assistant.hasRun = true; assistant.duration = Date().timeIntervalSince(started) }
        let prompt = """
        You are auditing a Claude Code user configuration under ~/.claude. Inspect the inventory \
        below and propose concrete cleanup actions — redundant or overlapping skills/agents/commands, \
        dead or broken paths, conflicting or duplicate permission rules, unused or duplicate MCP \
        servers, redundant hooks, anything stale or risky. Use your own judgment; there is no fixed \
        checklist.

        Respond with ONLY a JSON array, no prose and no markdown fences. Each element:
        {"title": "...", "rationale": "one or two sentences", "severity": "high|medium|low", \
        "paths": ["absolute paths involved, or empty"], "action": "delete|edit|review|note"}
        Return at most the 12 most worthwhile items. If nothing is worth changing, return [].

        INVENTORY:
        \(inventory)
        """
        do {
            let reply = try await assistant.service.run(prompt: prompt)
            assistant.suggestions = Self.parse(reply.text)
            if assistant.suggestions.isEmpty, !reply.text.contains("[]") {
                assistant.error = String(localized: "The model didn't return a usable list. Raw reply:\n\(String(reply.text.prefix(300)))")
            }
        } catch {
            assistant.error = error.localizedDescription
        }
    }

    /// Tolerant parse: strip optional ```json fences, decode the first JSON array.
    static func parse(_ text: String) -> [CleanupSuggestion] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start <= end {
            s = String(s[start...end])
        }
        guard let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CleanupSuggestion].self, from: data)) ?? []
    }
}

private struct SuggestionCard: View {
    let suggestion: CleanupSuggestion
    var onChange: () -> Void
    @State private var confirmingDelete: String?
    @State private var deleteError: String?

    private var tone: Color {
        switch suggestion.severity {
        case "high": return Theme.error
        case "medium": return Theme.warning
        default: return Theme.accent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(tone).frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Text(suggestion.title)
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.Space.sm)
                    Chip(text: suggestion.action)
                }
                Text(suggestion.rationale)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(suggestion.paths, id: \.self) { path in
                    HStack(spacing: Theme.Space.sm) {
                        Text(compactPath(path))
                            .font(Theme.Typo.mono)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1).truncationMode(.middle).help(path)
                        Spacer()
                        Button("Reveal in Finder") { reveal(path) }
                            .buttonStyle(GhostButtonStyle())
                        if suggestion.action == "delete", isDeletable(path) {
                            Button("Delete…") { confirmingDelete = path }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                if let deleteError {
                    Label(deleteError, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.error)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(tone)
                .frame(width: 2)
        }
        .shadow(color: Theme.shadow.opacity(0.05), radius: 5, y: 2)
        .confirmationDialog(
            "Delete this file?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) {
                if let p = confirmingDelete { delete(p) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("A backup is written to ~/.claude/backups first, so this can be undone.")
        }
    }

    /// The model picks deletion targets freely from its own reply — never trust a suggested
    /// path without confirming it actually resolves inside `~/.claude`.
    private func isWithinClaudeDir(_ url: URL) -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude").resolvingSymlinksInPath().path
        return url.path == claudeDir || url.path.hasPrefix(claudeDir + "/")
    }

    private func isDeletable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard exists, !isDir.boolValue else { return false }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return isWithinClaudeDir(url)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func delete(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard isWithinClaudeDir(url) else {
            deleteError = String(localized: "Refusing to delete a path outside ~/.claude")
            return
        }
        let backups = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude").appending(path: "backups")
        let guardian = WriteGuard(fileURL: url, backupDir: backups)
        do {
            try guardian.deleteWithBackup()
            deleteError = nil
            onChange()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Chat

private struct ChatPane: View {
    @ObservedObject var assistant: AssistantStore
    let inventory: String

    @State private var input = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var messages: [ChatMessage] { assistant.messages }
    private var sending: Bool { assistant.sending }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Space.sm) {
                        if messages.isEmpty {
                            Text("Ask about your config — “Any overlapping skills?”, “What's safe to delete?”")
                                .font(Theme.Typo.serifBody)
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Theme.Space.md)
                        }
                        ForEach(messages) { MessageBubble(message: $0) }
                        if sending {
                            HStack { ProgressView().controlSize(.small); Spacer() }
                        }
                    }
                    .padding(Theme.Space.lg)
                    .id("bottom")
                }
                .onChange(of: messages.count) { _, _ in
                    if reduceMotion {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(spacing: Theme.Space.sm) {
            IconButton("square.and.pencil", help: String(localized: "New conversation")) {
                assistant.messages = []
                assistant.sessionId = nil
            }
            .disabled(sending || messages.isEmpty)
            ThemedField(prompt: String(localized: "Ask claude about your config…"), text: $input)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        input = ""
        assistant.messages.append(ChatMessage(role: .user, text: text))
        assistant.sending = true
        Task {
            defer { assistant.sending = false }
            // First turn carries the inventory; later turns resume the CLI session.
            let prompt = assistant.sessionId == nil
                ? "Here is my ~/.claude config inventory. Help me reason about cleaning it up; be concise.\n\n\(inventory)\n\n---\nQuestion: \(text)"
                : text
            do {
                let reply = try await assistant.service.run(prompt: prompt, resume: assistant.sessionId)
                assistant.sessionId = reply.sessionId ?? assistant.sessionId
                assistant.messages.append(ChatMessage(role: .assistant, text: reply.text))
            } catch {
                assistant.messages.append(ChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)"))
            }
        }
    }
}

private struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    enum Role { case user, assistant }
}

private struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: Theme.Space.xl) }
            Text(message.text)
                .font(Theme.Typo.body)
                .foregroundStyle(isUser ? Color(light: .white, dark: .hex(0x211E1A)) : Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(isUser ? Theme.accentStrong : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(isUser ? .clear : Theme.border, lineWidth: 1)
                )
            if !isUser { Spacer(minLength: Theme.Space.xl) }
        }
    }
}
