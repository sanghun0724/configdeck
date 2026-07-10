import Foundation
import SwiftUI

enum PermissionKind: String, CaseIterable, Identifiable {
    case allow = "Allow"
    case ask = "Ask"
    case deny = "Deny"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .allow: return SemanticColor.success
        case .ask: return SemanticColor.warning
        case .deny: return SemanticColor.error
        }
    }

    /// Localized display label — `rawValue` itself stays the fixed English identity.
    var displayLabel: String {
        switch self {
        case .allow: return String(localized: "Allow")
        case .ask: return String(localized: "Ask")
        case .deny: return String(localized: "Deny")
        }
    }
}

/// Live, editable model for settings.json permissions. Read for env (#6 explicit save,
/// #4 validate, #3 preserve-unknown via SettingsSerializer, #1/#2/#5/#7 via WriteGuard).
@MainActor
final class SettingsStore: ObservableObject, GuardedStore {
    @Published var allow: [String] = []
    @Published var ask: [String] = []
    @Published var deny: [String] = []
    @Published var envVars: [EnvVar] = []
    @Published var hookEntries: [HookEditEntry] = []
    @Published var statusMessage: String?
    @Published var isError = false
    @Published var isStale = false
    @Published var canRestore = false

    private var root: [String: Any] = [:]
    private var loadedHash = ""
    private var orig: (allow: [String], ask: [String], deny: [String]) = ([], [], [])
    private var origEnv: [EnvVar] = []
    /// Raw env values as loaded — untouched entries are written back with their
    /// original JSON type (bool/number), not coerced to strings.
    private var origEnvRaw: [String: Any] = [:]
    private var hooksDirty = false
    private let fileURL: URL
    private let guardian: WriteGuard
    private var watcher: FileWatcher?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let claude = home.appending(path: ".claude")
        self.fileURL = claude.appending(path: "settings.json")
        self.guardian = WriteGuard(fileURL: fileURL, backupDir: claude.appending(path: "backups"))
        load()
        watcher = FileWatcher(url: fileURL) { [weak self] in self?.externalChange() }
    }

    /// External change detected by the watcher: our own writes are filtered by hash;
    /// clean state reloads silently, dirty state raises the stale banner instead of
    /// clobbering the user's edits.
    private func externalChange() {
        guard let data = try? Data(contentsOf: fileURL.resolvingSymlinksInPath()) else {
            isStale = true
            statusMessage = String(localized: "File removed on disk — Save will recreate it.")
            return
        }
        if WriteGuard.hash(data) == loadedHash { return }
        if hasChanges {
            isStale = true
            statusMessage = String(localized: "Changed on disk — Reload takes the disk version; your unsaved edits are kept until then.")
        } else {
            load()
            statusMessage = String(localized: "Reloaded — the file changed on disk.")
        }
    }

    var hasChanges: Bool {
        allow != orig.allow || ask != orig.ask || deny != orig.deny || envVars != origEnv || hooksDirty
    }

    func rules(_ kind: PermissionKind) -> [String] {
        switch kind {
        case .allow: return allow
        case .ask: return ask
        case .deny: return deny
        }
    }

    func load() {
        isStale = false
        isError = false
        statusMessage = nil
        guard let data = try? Data(contentsOf: fileURL.resolvingSymlinksInPath()) else {
            // Fresh install: no settings.json yet. Editing works — first Save creates it.
            statusMessage = String(localized: "settings.json doesn't exist yet — it will be created on first save.")
            root = [:]
            loadedHash = ""
            allow = []; ask = []; deny = []
            orig = ([], [], [])
            envVars = []
            origEnv = []
            origEnvRaw = [:]
            loadHooks()
            canRestore = !guardian.backups().isEmpty
            return
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isError = true
            statusMessage = String(localized: "settings.json is not valid JSON — fix it externally or restore a backup.")
            return
        }
        root = dict
        loadedHash = WriteGuard.hash(data)
        let perms = dict["permissions"] as? [String: Any] ?? [:]
        allow = perms["allow"] as? [String] ?? []
        ask = perms["ask"] as? [String] ?? []
        deny = perms["deny"] as? [String] ?? []
        orig = (allow, ask, deny)
        origEnvRaw = dict["env"] as? [String: Any] ?? [:]
        envVars = origEnvRaw
            .map { EnvVar(key: $0.key, value: String(describing: $0.value)) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        origEnv = envVars
        loadHooks()
        canRestore = !guardian.backups().isEmpty
    }

    private func loadHooks() {
        var entries: [HookEditEntry] = []
        if let hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    let matcher = group["matcher"] as? String ?? "*"
                    let cmds = (group["hooks"] as? [[String: Any]] ?? [])
                        .compactMap { $0["command"] as? String }
                    entries.append(HookEditEntry(event: event, matcher: matcher, commands: cmds, raw: group))
                }
            }
        }
        hookEntries = entries.sorted {
            $0.event.localizedCaseInsensitiveCompare($1.event) == .orderedAscending
        }
        hooksDirty = false
    }

    /// Rebuild hooks dict: untouched entries keep their original group (preserve-unknown);
    /// newly added ones become a single command hook.
    private func rebuiltHooks() -> [String: Any] {
        var byEvent: [String: [Any]] = [:]
        for e in hookEntries {
            let group: [String: Any] = e.raw ?? [
                "matcher": e.matcher,
                "hooks": [["type": "command", "command": e.commands.first ?? ""]]
            ]
            byEvent[e.event, default: []].append(group)
        }
        return byEvent
    }

    func addHook(event: String, matcher: String, command: String) {
        let ev = event.trimmingCharacters(in: .whitespaces)
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !ev.isEmpty, !cmd.isEmpty else { return }
        let m = matcher.trimmingCharacters(in: .whitespaces)
        hookEntries.append(HookEditEntry(
            event: ev, matcher: m.isEmpty ? "*" : m, commands: [cmd], raw: nil))
        hookEntries.sort { $0.event.localizedCaseInsensitiveCompare($1.event) == .orderedAscending }
        hooksDirty = true
    }

    func removeHook(at offsets: IndexSet) {
        hookEntries.remove(atOffsets: offsets)
        hooksDirty = true
    }

    func addRule(_ raw: String, to kind: PermissionKind) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch kind {
        case .allow: if !allow.contains(v) { allow.append(v) }
        case .ask: if !ask.contains(v) { ask.append(v) }
        case .deny: if !deny.contains(v) { deny.append(v) }
        }
    }

    func remove(_ kind: PermissionKind, at offsets: IndexSet) {
        switch kind {
        case .allow: allow.remove(atOffsets: offsets)
        case .ask: ask.remove(atOffsets: offsets)
        case .deny: deny.remove(atOffsets: offsets)
        }
    }

    func addEnv(key: String, value: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !envVars.contains(where: { $0.key == k }) else { return }
        envVars.append(EnvVar(key: k, value: value))
        envVars.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    func removeEnv(at offsets: IndexSet) {
        envVars.remove(atOffsets: offsets)
    }

    func removeRule(_ kind: PermissionKind, value: String) {
        switch kind {
        case .allow: allow.removeAll { $0 == value }
        case .ask: ask.removeAll { $0 == value }
        case .deny: deny.removeAll { $0 == value }
        }
    }

    func removeEnv(id: UUID) {
        envVars.removeAll { $0.id == id }
    }

    func removeHook(id: UUID) {
        hookEntries.removeAll { $0.id == id }
        hooksDirty = true
    }

    func discard() {
        allow = orig.allow
        ask = orig.ask
        deny = orig.deny
        envVars = origEnv
        loadHooks()
        isError = false
        statusMessage = nil
    }

    func save() {
        isError = false
        statusMessage = nil
        // #4 validate
        if (allow + ask + deny).contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            fail(String(localized: "Empty rule not allowed"))
            return
        }
        if envVars.contains(where: { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }) {
            fail(String(localized: "Empty env key not allowed"))
            return
        }
        if Set(envVars.map(\.key)).count != envVars.count {
            fail(String(localized: "Duplicate env key not allowed"))
            return
        }
        var merged = SettingsSerializer.apply(root: root, allow: allow, ask: ask, deny: deny)
        // #3: only rewrite env when it actually changed — and even then, entries the
        // user didn't touch keep their original JSON type (bool/number stay as-is).
        if envVars != origEnv {
            var env: [String: Any] = [:]
            for entry in envVars {
                if let original = origEnvRaw[entry.key], String(describing: original) == entry.value {
                    env[entry.key] = original
                } else {
                    env[entry.key] = entry.value
                }
            }
            merged["env"] = env
        }
        if hooksDirty {
            let hooks = rebuiltHooks()
            if hooks.isEmpty { merged["hooks"] = nil } else { merged["hooks"] = hooks }
        }
        guard let data = try? SettingsSerializer.serialize(merged) else {
            fail(String(localized: "Serialization failed"))
            return
        }
        do {
            try guardian.commit(data, expectedHash: loadedHash)
            root = merged
            loadedHash = WriteGuard.hash(data)
            orig = (allow, ask, deny)
            origEnv = envVars
            origEnvRaw = merged["env"] as? [String: Any] ?? [:]
            loadHooks()   // refresh raw groups + clear dirty
            canRestore = true
            statusMessage = String(localized: "Saved — backup created.")
        } catch let error as WriteGuardError where error == .staleFile {
            isStale = true
            fail(error.localizedDescription)
        } catch {
            fail(error.localizedDescription)
        }
    }

    var backupList: [URL] { guardian.backups() }

    func restore() {
        do {
            try guardian.restoreLatest(expectedHash: loadedHash)
            load()
            statusMessage = String(localized: "Restored from latest backup.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func restore(from backup: URL) {
        do {
            try guardian.restore(from: backup, expectedHash: loadedHash)
            load()
            statusMessage = String(localized: "Restored from backup.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        isError = true
        statusMessage = message
    }
}

extension WriteGuardError: Equatable {}

struct HookEditEntry: Identifiable {
    let id = UUID()
    var event: String
    var matcher: String
    var commands: [String]
    /// Original group dict for existing entries — replayed verbatim on save to preserve
    /// any non-command hook fields. nil for newly added entries.
    var raw: [String: Any]?

    /// Hooks in this group that aren't `command` type (url, mcp, …) — preserved on
    /// save but not editable here; surfaced so deleting the group isn't a surprise.
    var otherHookCount: Int {
        guard let raw, let hooks = raw["hooks"] as? [[String: Any]] else { return 0 }
        return hooks.filter { ($0["command"] as? String) == nil }.count
    }
}
