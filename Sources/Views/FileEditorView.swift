import SwiftUI

/// Raw, guarded text editor for a single markdown config file.
/// Whole-file write through WriteGuard — no frontmatter reserialization, so the
/// body is never silently mangled.
struct FileEditorView: View {
    let title: String
    let path: String
    var onChange: () -> Void = {}
    @StateObject private var store: TextFileStore
    @EnvironmentObject private var editorDirty: EditorDirtyState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @AppStorage("editorMode") private var mode: EditorMode = .live
    @AppStorage("hasSeenLiveModeHint") private var hasSeenLiveModeHint = false
    @State private var findTrigger = 0

    enum EditorMode: String, CaseIterable {
        case raw = "Raw", live = "Live", preview = "Preview"
    }

    init(title: String, path: String, onChange: @escaping () -> Void = {}) {
        self.title = title
        self.path = path
        self.onChange = onChange
        _store = StateObject(wrappedValue: TextFileStore(path: path))
    }

    /// skills/agents/commands are commonly symlinked to an external config repo.
    private var isExternal: Bool { !path.contains("/.claude/") }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if isExternal {
                WarningBanner(text: String(localized: "External repo — saving writes to \(path) (outside ~/.claude). Backups still go to ~/.claude/backups."))
            }
            if store.isLarge {
                WarningBanner(text: String(localized: "Large file — typing may lag. Consider an external editor for heavy edits."))
            }
            FrontmatterCard(text: store.text)
            editorBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            ActionBar(store: store, onChange: onChange)
        }
        .background {
            Group {
                Button("") { mode = .raw }.keyboardShortcut("1", modifiers: .command)
                Button("") { mode = .live }.keyboardShortcut("2", modifiers: .command)
                Button("") { mode = .preview }.keyboardShortcut("3", modifiers: .command)
                // Live only — in Raw mode ⌘F must fall through to the system
                // find bar of the TextEditor instead of being swallowed here.
                if mode == .live {
                    Button("") { findTrigger += 1 }.keyboardShortcut("f", modifiers: .command)
                }
            }
            .hidden()
        }
        .navigationTitle(title)
        .onChange(of: store.hasChanges) { _, dirty in editorDirty.isDirty = dirty }
        .onDisappear { editorDirty.isDirty = false }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete file", role: .destructive) {
                if store.delete() {
                    onChange()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is saved to ~/.claude/backups first, so this can be undone. The file at \(path) will be removed.")
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Kicker(text: "\(String(localized: "Editing")) · \((path as NSString).lastPathComponent)")
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.Typo.serifTitle)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if store.hasChanges {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .transition(.opacity)
                    }
                }
                .motion(Theme.Motion.quick, value: store.hasChanges)
            }
            .help(path)

            Spacer()

            SegmentedControl(
                selection: $mode,
                options: [
                    (value: .raw, label: String(localized: "Raw")),
                    (value: .live, label: String(localized: "Live")),
                    (value: .preview, label: String(localized: "Preview"))
                ]
            )
            .frame(width: 190)

            IconButton("trash", role: .destructive, help: String(localized: "Delete this file (backed up first)")) {
                confirmingDelete = true
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 58)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: - Editor body

    @ViewBuilder
    private var editorBody: some View {
        switch mode {
        case .preview:
            MarkdownPreview(text: store.text)
        case .live:
            ZStack(alignment: .top) {
                MarkdownHybridEditor(text: $store.text, findTrigger: findTrigger)
                if !hasSeenLiveModeHint {
                    liveModeHint
                }
            }
        case .raw:
            TextEditor(text: $store.text)
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .font(.system(size: MarkdownTheme.bodySize, design: .monospaced))
                .lineSpacing(MarkdownTheme.lineSpacing)
                .autocorrectionDisabled()
                .padding(.vertical, 16)
                .padding(.horizontal, MarkdownTheme.editorInset)
        }
    }

    /// One-time nudge explaining the Live mode hidden-markup mechanic — dismissed
    /// on first close and never shown again.
    private var liveModeHint: some View {
        HStack(spacing: 8) {
            Text("Markdown symbols only show on the line the cursor is on.")
                .font(.system(size: 11.5, design: .serif))
                .italic()
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
            Button {
                hasSeenLiveModeHint = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .padding(10)
        .transition(.opacity)
    }
}

/// Live, read-only preview of the file's frontmatter — parses on every keystroke
/// so a malformed key/value is obvious immediately, but never writes back
/// (round-tripping the raw block risked mangling multi-line values FrontmatterParser
/// doesn't model, e.g. YAML list `triggers:`). Renders nothing when there's no
/// `name` key, so files without frontmatter are unaffected.
private struct FrontmatterCard: View {
    let text: String

    var body: some View {
        let fields = FrontmatterParser.parse(text)
        if let name = fields["name"], !name.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: "Frontmatter")
                Text(name)
                    .font(Theme.Typo.serifTitle)
                    .foregroundStyle(Theme.ink)
                if let description = fields["description"], !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
                let tools = (fields["allowed-tools"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !tools.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tools, id: \.self) { Chip(text: $0) }
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }
}
