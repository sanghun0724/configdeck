import SwiftUI

/// Persistent state for the Sessions section — owned by `AppShell` (like
/// `AssistantStore`) so the scanned list, lazy title cache and open transcript
/// survive tab switches. Strictly read-only: no WriteGuard, no FileWatcher —
/// browsing transcripts never touches the files.
@MainActor
final class SessionsStore: ObservableObject {
    @Published var projects: [SessionProject] = []
    @Published var isScanning = false
    @Published var hasLoaded = false
    /// Lazy per-file title cache — filled as rows become visible.
    @Published var titles: [String: String] = [:]

    @Published var openPath: String?
    @Published var openTranscript: SessionTranscript?
    @Published var isLoadingTranscript = false
    /// In-session turn filter — prefilled when a content-search hit is opened.
    @Published var detailQuery = ""

    @Published var searchHits: [SessionSearchHit] = []
    @Published var isSearching = false
    @Published var searchScanned = 0
    @Published var searchTotal = 0

    private var titleRequests: Set<String> = []
    private var searchTask: Task<Void, Never>?

    func loadIfNeeded() {
        guard !hasLoaded, !isScanning else { return }
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                SessionScanner().scan()
            }.value
            projects = scanned
            hasLoaded = true
            isScanning = false
        }
    }

    func fetchTitle(for summary: SessionSummary) {
        let path = summary.path
        guard titles[path] == nil, !titleRequests.contains(path) else { return }
        titleRequests.insert(path)
        Task {
            let title = await Task.detached(priority: .utility) {
                SessionScanner().title(for: path)
            }.value
            titles[path] = title ?? summary.sessionId
        }
    }

    func open(_ path: String) {
        guard openPath != path else { return }
        openPath = path
        openTranscript = nil
        isLoadingTranscript = true
        Task {
            let transcript = await Task.detached(priority: .userInitiated) {
                SessionTranscriptParser.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            }.value
            guard openPath == path else { return }   // another row was opened meanwhile
            openTranscript = transcript
            isLoadingTranscript = false
        }
    }

    /// Snapshot semantics: a still-running session keeps appending — re-read on demand.
    func reloadOpen() {
        guard let path = openPath else { return }
        openPath = nil
        open(path)
    }

    func contentSearch(query: String, files: [String]) {
        searchTask?.cancel()
        searchHits = []
        searchScanned = 0
        searchTotal = files.count
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            SessionContentSearcher().search(
                query: query,
                in: files,
                isCancelled: { Task.isCancelled },
                onProgress: { scanned in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.searchScanned = max(self.searchScanned, scanned)
                    }
                },
                onHit: { hit in
                    Task { @MainActor [weak self] in self?.searchHits.append(hit) }
                }
            )
            await MainActor.run { [weak self] in self?.isSearching = false }
        }
    }

    func cancelContentSearch() {
        searchTask?.cancel()
        isSearching = false
    }
}

/// Read-only browser for past Claude Code sessions (`~/.claude/projects/*/*.jsonl`).
/// Reading a transcript here costs zero tokens — unlike `claude --resume`, which
/// loads the whole conversation back into context.
struct SessionsView: View {
    @ObservedObject var store: SessionsStore

    enum SearchMode: Hashable { case titles, content }
    enum DateRange: Hashable, CaseIterable {
        case all, today, week, month

        var cutoff: Date? {
            switch self {
            case .all: return nil
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            }
        }
    }

    @State private var query = ""
    @State private var searchMode: SearchMode = .titles
    @State private var dateRange: DateRange = .all
    @State private var projectFilter: String?   // SessionProject.dirPath
    @State private var selectedPath: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .task { store.loadIfNeeded() }
    }

    // MARK: - Header

    private var sessionCount: Int { store.projects.reduce(0) { $0 + $1.sessions.count } }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Text("Sessions")
                .font(Theme.Typo.serifTitle)
                .foregroundStyle(Theme.ink)
            Text("\(sessionCount) transcripts")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            projectPicker
            SegmentedControl(
                selection: $dateRange,
                options: [
                    (value: .all, label: String(localized: "All")),
                    (value: .today, label: String(localized: "Today")),
                    (value: .week, label: String(localized: "7d")),
                    (value: .month, label: String(localized: "30d"))
                ]
            )
            .frame(width: 220)
            SegmentedControl(
                selection: $searchMode,
                options: [
                    (value: .titles, label: String(localized: "Titles")),
                    (value: .content, label: String(localized: "Content"))
                ]
            )
            .frame(width: 130)
            SearchField(prompt: searchPrompt, text: $query, focus: $searchFocused)
                .frame(width: 200)
                .onSubmit(submitSearch)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(height: Theme.Dim.topBarHeight + 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onChange(of: searchMode) { _, _ in store.cancelContentSearch() }
    }

    private var searchPrompt: String {
        searchMode == .content
            ? String(localized: "Search content — press ⏎")
            : String(localized: "Search sessions")
    }

    private var projectPicker: some View {
        Picker("Project", selection: $projectFilter) {
            Text("All Projects").tag(String?.none)
            ForEach(store.projects) { project in
                Text(tail(of: project.displayPath)).tag(String?.some(project.dirPath))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private func submitSearch() {
        guard searchMode == .content, !query.isEmpty else { return }
        store.contentSearch(query: query, files: contentSearchFiles)
    }

    // MARK: - Filtering

    private var dateFilteredProjects: [SessionProject] {
        let cutoff = dateRange.cutoff
        return store.projects
            .filter { projectFilter == nil || $0.dirPath == projectFilter }
            .map { project in
                var filtered = project
                filtered.sessions = project.sessions.filter { cutoff == nil || $0.modified >= cutoff! }
                return filtered
            }
            .filter { !$0.sessions.isEmpty }
    }

    /// Title-mode filter on top of the project/date filter. Matches only cached
    /// titles — rows scrolled past at least once — plus session id and project path.
    private var visibleProjects: [SessionProject] {
        guard searchMode == .titles, !query.isEmpty else { return dateFilteredProjects }
        return dateFilteredProjects
            .map { project in
                var filtered = project
                filtered.sessions = project.sessions.filter(titleMatches)
                return filtered
            }
            .filter { !$0.sessions.isEmpty }
    }

    private func titleMatches(_ session: SessionSummary) -> Bool {
        session.sessionId.localizedCaseInsensitiveContains(query)
            || session.projectDisplayPath.localizedCaseInsensitiveContains(query)
            || (store.titles[session.path]?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// Newest-first file list for a global content scan (project/date filter applied).
    private var contentSearchFiles: [String] {
        dateFilteredProjects
            .flatMap(\.sessions)
            .sorted { $0.modified > $1.modified }
            .map(\.path)
    }

    private var summaryByPath: [String: SessionSummary] {
        Dictionary(
            store.projects.flatMap(\.sessions).map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func tail(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.projects.isEmpty {
            EmptyHint(label: String(localized: "sessions"), dir: "~/.claude/projects")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                index
                    .frame(width: Theme.Dim.indexWidth)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                detailPane
            }
        }
    }

    @ViewBuilder
    private var index: some View {
        if searchMode == .content, !query.isEmpty {
            contentHits
        } else if visibleProjects.isEmpty {
            EmptySearchHint(label: String(localized: "sessions"), query: $query)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleProjects) { project in
                    if projectFilter == nil {
                        Kicker(text: tail(of: project.displayPath))
                            .padding(.horizontal, Theme.Space.lg)
                            .padding(.top, Theme.Space.md)
                            .padding(.bottom, Theme.Space.xs)
                    }
                    ForEach(project.sessions) { session in
                        SessionIndexRow(
                            summary: session,
                            title: store.titles[session.path],
                            isSelected: session.path == selectedPath
                        ) {
                            openSession(session.path)
                        }
                        .task { store.fetchTitle(for: session) }
                    }
                }
            }
            .padding(.vertical, Theme.Space.sm)
        }
    }

    private var contentHits: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                if store.isSearching {
                    ProgressView(value: Double(store.searchScanned), total: Double(max(store.searchTotal, 1)))
                        .controlSize(.small)
                }
                Text(store.isSearching
                     ? "\(store.searchScanned)/\(store.searchTotal)"
                     : String(localized: "\(store.searchHits.count) sessions match"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }

            if store.searchHits.isEmpty && !store.isSearching {
                EmptySearchHint(label: String(localized: "sessions"), query: $query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.searchHits) { hit in
                            if let summary = summaryByPath[hit.path] {
                                ContentHitRow(
                                    hit: hit,
                                    summary: summary,
                                    title: store.titles[hit.path],
                                    isSelected: hit.path == selectedPath
                                ) {
                                    openSession(hit.path, prefill: query)
                                }
                                .task { store.fetchTitle(for: summary) }
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.sm)
                }
            }
        }
    }

    private func openSession(_ path: String, prefill: String = "") {
        selectedPath = path
        store.detailQuery = prefill
        store.open(path)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let path = selectedPath, let summary = summaryByPath[path] {
            TranscriptPane(store: store, summary: summary)
        } else {
            ContentUnavailableView {
                Label("Select a session", systemImage: "text.bubble")
            } description: {
                Text("Transcripts are read directly from disk — no tokens, no resume.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Index rows

private struct SessionIndexRow: View {
    let summary: SessionSummary
    let title: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? summary.sessionId)
                    .font(Theme.Typo.serifRow)
                    .foregroundStyle(isSelected ? Theme.accentStrong : Theme.ink)
                    .lineLimit(1)
                    .redacted(reason: title == nil ? .placeholder : [])
                Text("\(relativeTime(summary.modified)) · \(Int64(summary.sizeBytes).formatted(.byteCount(style: .file)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.divider : .clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, Theme.Space.lg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Theme.Motion.quick, value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ContentHitRow: View {
    let hit: SessionSearchHit
    let summary: SessionSummary
    let title: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? summary.sessionId)
                    .font(Theme.Typo.serifRow)
                    .foregroundStyle(isSelected ? Theme.accentStrong : Theme.ink)
                    .lineLimit(1)
                    .redacted(reason: title == nil ? .placeholder : [])
                Text(hit.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Chip(text: "\(hit.matchCount)", tone: .accent)
                    Text(relativeTime(summary.modified))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.divider : .clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, Theme.Space.lg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Theme.Motion.quick, value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Transcript pane

private struct TranscriptPane: View {
    @ObservedObject var store: SessionsStore
    let summary: SessionSummary
    @State private var showSidechain = false

    private var transcript: SessionTranscript? { store.openTranscript }

    private var filteredTurns: [SessionTurn] {
        guard let transcript else { return [] }
        return transcript.turns.filter { turn in
            (showSidechain || !turn.isSidechain)
                && (store.detailQuery.isEmpty || turnText(turn).localizedCaseInsensitiveContains(store.detailQuery))
        }
    }

    private func turnText(_ turn: SessionTurn) -> String {
        switch turn.kind {
        case let .user(text): return text
        case let .assistantText(markdown): return markdown
        case let .thinking(text): return text
        case let .toolUse(name, inputSummary): return "\(name) \(inputSummary)"
        case let .toolResult(text, _): return text
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            if store.isLoadingTranscript {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if transcript != nil {
                turnList
            }
        }
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Kicker(text: "\(String(localized: "Session")) · \(URL(fileURLWithPath: summary.projectDisplayPath).lastPathComponent)")
                Spacer()
                Toggle("Subagents", isOn: $showSidechain)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                IconButton("arrow.clockwise", help: String(localized: "Re-read transcript")) {
                    store.reloadOpen()
                }
            }
            Text(store.titles[summary.path] ?? transcript?.title ?? summary.sessionId)
                .font(Theme.Typo.serifDisplay)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            metaRow
            HStack(spacing: Theme.Space.sm) {
                SearchField(prompt: String(localized: "Filter turns"), text: $store.detailQuery)
                    .frame(maxWidth: 260)
                Text(summary.path)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary.path)
                    .pathContextMenu(summary.path)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(summary.modified.formatted(date: .abbreviated, time: .shortened))
            if let transcript {
                Text("·").foregroundStyle(Theme.inkTertiary)
                Text("\(transcript.turns.count) turns")
                if let model = transcript.model {
                    Chip(text: model)
                }
                if let branch = transcript.gitBranch {
                    Chip(text: branch, tone: .accent)
                }
                if transcript.skippedLines > 0 {
                    Text("\(transcript.skippedLines) lines skipped")
                        .foregroundStyle(Theme.warningInk)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Theme.inkSecondary)
    }

    private var turnList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(filteredTurns) { turn in
                    TurnView(turn: turn)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.lg)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Turns

private struct TurnView: View {
    let turn: SessionTurn

    var body: some View {
        switch turn.kind {
        case let .user(text):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Kicker(text: String(localized: "You"))
                    if turn.isSidechain { Chip(text: "subagent") }
                }
                Text(text)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        case let .assistantText(markdown):
            MarkdownBlocksView(text: markdown)
                .textSelection(.enabled)
        case let .thinking(text):
            CollapsedTurn(label: String(localized: "Thinking"), detail: nil) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }
        case let .toolUse(name, inputSummary):
            CollapsedTurn(label: name, detail: firstLine(of: inputSummary)) {
                Text(inputSummary)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }
        case let .toolResult(text, isError):
            CollapsedTurn(
                label: isError ? String(localized: "Error") : String(localized: "Result"),
                detail: firstLine(of: text),
                tint: isError ? Theme.error : nil
            ) {
                Text(text)
                    .font(Theme.Typo.mono)
                    .foregroundStyle(isError ? Theme.error : Theme.inkSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func firstLine(of text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }
}

/// Collapsed one-liner for tool calls / thinking — a chip label plus the first
/// line, expanding to the full payload on click.
private struct CollapsedTurn<Content: View>: View {
    let label: String
    let detail: String?
    var tint: Color?
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Chip(text: label, tone: tint == nil ? .neutral : .accent)
                if let detail {
                    Text(detail)
                        .font(Theme.Typo.mono)
                        .foregroundStyle(tint ?? Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
        .disclosureGroupStyle(.automatic)
        .tint(Theme.inkTertiary)
    }
}
