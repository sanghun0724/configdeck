import AppKit
import SwiftUI

enum ConfigSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case agents = "Agents"
    case commands = "Commands"
    case sessions = "Sessions"
    case mcp = "MCP Servers"
    case hooks = "Hooks"
    case settings = "Settings"
    case assistant = "Assistant"

    var id: String { rawValue }
}

/// FileEditorView (deep inside a section's NavigationStack) reports unsaved text
/// edits here, so the sidebar can warn before a section switch tears the editor
/// down and silently discards them.
@MainActor
final class EditorDirtyState: ObservableObject {
    @Published var isDirty = false
}

/// Custom two-pane shell. Replaces NavigationSplitView with a hand-built rail + detail.
/// Owns `selection` and the single shared `SettingsStore` (Hooks and Settings edit the
/// same settings.json — they MUST share one instance). Scan runs off the main thread.
struct AppShell: View {
    @State private var data = ConfigData.empty
    @AppStorage("selectedSection") private var selection: ConfigSection = .skills
    @State private var pendingSelection: ConfigSection?
    @State private var isScanning = false
    @State private var hasLoaded = false
    @StateObject private var settings = SettingsStore()
    @StateObject private var mcp = MCPStore()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var sessions = SessionsStore()
    @StateObject private var editorDirty = EditorDirtyState()
    @State private var availableUpdate: String?
    /// Tag the user dismissed — that version stays hidden, the next one banners again.
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""

    var body: some View {
        VStack(spacing: 0) {
            if let tag = availableUpdate, tag != skippedUpdateVersion {
                UpdateBanner(tag: tag, onSkip: { skippedUpdateVersion = tag })
            }
            HStack(spacing: 0) {
                SidebarView(
                    selection: guardedSelection,
                    counts: count,
                    onReload: { Task { await reload() } },
                    isScanning: isScanning
                )
                detail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .environmentObject(editorDirty)
        .task { await reload() }
        .task { availableUpdate = await UpdateChecker.checkForUpdate() }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { pendingSelection != nil },
                set: { if !$0 { pendingSelection = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                if let pending = pendingSelection { selection = pending }
                pendingSelection = nil
                editorDirty.isDirty = false
            }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("The open editor has unsaved changes. Switching sections closes it and loses them.")
        }
    }

    /// Routes sidebar clicks through the unsaved-editor check.
    private var guardedSelection: Binding<ConfigSection> {
        Binding(
            get: { selection },
            set: { newSection in
                guard newSection != selection else { return }
                if editorDirty.isDirty {
                    pendingSelection = newSection
                } else {
                    selection = newSection
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            Theme.bg
            if isScanning && !hasLoaded {
                SkeletonList()
            } else {
                section
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var section: some View {
        switch selection {
        case .skills:
            SkillsView(skills: data.skills, dir: "\(data.claudeDir)/skills", onChange: triggerReload)
        case .agents:
            AgentsView(agents: data.agents, dir: "\(data.claudeDir)/agents", onChange: triggerReload)
        case .commands:
            CommandsView(commands: data.commands, dir: "\(data.claudeDir)/commands", onChange: triggerReload)
        case .sessions:
            SessionsView(store: sessions)
        case .mcp:
            MCPView(store: mcp, onChange: triggerReload)
        case .hooks:
            HooksView(store: settings, onChange: triggerReload)
        case .settings:
            SettingsView(store: settings, extraUnsaved: mcp.hasChanges, onChange: triggerReload)
        case .assistant:
            AssistantView(data: data, assistant: assistant, onChange: triggerReload)
        }
    }

    private func count(_ section: ConfigSection) -> Int {
        switch section {
        case .skills: return data.skills.count
        case .agents: return data.agents.count
        case .commands: return data.commands.count
        case .sessions: return -1   // no launch-time scan of ~/.claude/projects — sidebar hides it
        case .mcp: return data.mcpServers.count
        case .hooks: return data.hooks.count
        case .settings: return data.allow.count + data.deny.count + data.ask.count + data.envVars.count
        case .assistant: return -1   // not a count — sidebar hides it
        }
    }

    private func triggerReload() { Task { await reload() } }

    private func reload() async {
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) {
            ConfigScanner().scan()
        }.value
        data = scanned
        hasLoaded = true
        isScanning = false
    }
}

/// Thin top bar shown when a newer release exists. The curl installer is the
/// only update path, so the action is "copy the install command", not download.
private struct UpdateBanner: View {
    let tag: String
    let onSkip: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Theme.accent)
            Text("ConfigDeck \(tag) is available")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accentStrong)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(UpdateChecker.installCommand, forType: .string)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy Install Command")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .buttonStyle(.plain)
            .help("Skip this version")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 6)
        .background(Theme.accentSoft)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
}

/// Warm placeholder cards shown during the first scan — paper cards, redacted.
private struct SkeletonList: View {
    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Configuration item name")
                        .font(.system(size: 14, weight: .semibold))
                    Text("A short description line standing in while scanning ~/.claude")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
            Spacer()
        }
        .padding(Theme.Space.lg)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}
