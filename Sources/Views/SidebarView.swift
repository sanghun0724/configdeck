import SwiftUI

/// Custom navigation rail — the 서재 sidebar from the design: logo header, grouped
/// sections under mono kickers (라이브러리 / 시스템 / 도구), and a footer that keeps
/// the safety net visible (~/.claude path + latest-backup badge). `.focusSection()`
/// keeps arrow-key traversal between the rail and the detail pane.
struct SidebarView: View {
    @Binding var selection: ConfigSection
    let counts: (ConfigSection) -> Int
    let onReload: () -> Void
    var isScanning: Bool

    private static let groups: [(kicker: String, sections: [ConfigSection])] = [
        (String(localized: "Library"), [.skills, .agents, .commands]),
        (String(localized: "System"), [.hooks, .mcp, .settings]),
        (String(localized: "Tools"), [.assistant]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo

            ForEach(Self.groups, id: \.kicker) { group in
                Kicker(text: group.kicker)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, Theme.Space.xs)
                VStack(spacing: 1) {
                    ForEach(group.sections) { section in
                        SidebarRow(
                            section: section,
                            count: counts(section),
                            isSelected: selection == section
                        ) { selection = section }
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
            }

            Spacer(minLength: 0)

            footer
        }
        .focusSection()
        .frame(width: Theme.Dim.sidebarWidth)
        .background(Theme.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    // MARK: - Logo

    private var logo: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 28, height: 28)
                .overlay(Circle().fill(Color.hex(0xFBF9F4)).frame(width: 9, height: 9))
                .shadow(color: Theme.shadow.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Config")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Config Dashboard")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xs)
    }

    // MARK: - Footer (safety net stays visible)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("~/.claude")
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.inkTertiary)
            HStack(spacing: Theme.Space.xs) {
                BackupBadge(rescanTrigger: isScanning)
                Spacer()
                ThemeToggle()
                IconButton("arrow.clockwise", help: isScanning ? String(localized: "Scanning…") : String(localized: "Rescan")) {
                    onReload()
                }
                .disabled(isScanning)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.md)
    }
}

/// ◐ — cycles system → light → dark (design: per-window theme toggle).
private struct ThemeToggle: View {
    @AppStorage("appearance") private var appearance = "system"

    private var help: String {
        switch appearance {
        case "light": return String(localized: "Theme · Light")
        case "dark": return String(localized: "Theme · Dark")
        default: return String(localized: "Theme · System")
        }
    }

    var body: some View {
        IconButton(
            appearance == "dark" ? "circle.righthalf.filled" : "circle.lefthalf.filled",
            help: help
        ) {
            appearance = appearance == "system" ? "light" : appearance == "light" ? "dark" : "system"
        }
    }
}

/// "백업됨 · 2분 전" — reads the newest .bak in ~/.claude/backups.
private struct BackupBadge: View {
    /// Flips on every config rescan (AppShell's `isScanning`) so the badge re-reads
    /// the backups dir after a save/restore/delete instead of only once at launch.
    let rescanTrigger: Bool
    @State private var latest: Date?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(latest == nil ? Theme.inkTertiary : Theme.success)
                .frame(width: 7, height: 7)
            Text(latest.map { String(localized: "Backed up · \(relativeTime($0))") } ?? String(localized: "No backups yet"))
                .font(.system(size: 11))
        }
        .foregroundStyle(latest == nil ? Theme.inkTertiary : Theme.successInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(latest == nil ? Theme.divider : Theme.successSoft)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: rescanTrigger) { refresh() }
        .help(latest == nil
            ? "Backups are created automatically the first time you save — stored in ~/.claude/backups"
            : "Latest backup in ~/.claude/backups")
    }

    private func refresh() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude").appending(path: "backups")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        latest = items
            .filter { $0.pathExtension == "bak" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }
}

private struct SidebarRow: View {
    let section: ConfigSection
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Text(LocalizedStringKey(section.rawValue))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentStrong : Theme.inkSecondary)
                Spacer(minLength: Theme.Space.xs)
                if count >= 0 {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? Theme.accentStrong : Theme.inkTertiary)
                } else if isSelected {
                    Text("✦")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accentStrong)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.Dim.rowMinHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (hovering ? Theme.divider : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(Theme.Motion.quick, value: hovering)
        .accessibilityLabel(
            count >= 0
                ? Text(LocalizedStringKey(section.rawValue)) + Text(", \(count) items")
                : Text(LocalizedStringKey(section.rawValue))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
