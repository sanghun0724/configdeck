import Foundation
import SwiftUI

struct MCPEdit: Identifiable, Equatable {
    let id = UUID()
    /// Name this server had at load time — keys the lookup that preserves untouched
    /// fields (env, headers, …) across a rename. nil = newly added, nothing to preserve.
    var originalName: String?
    var name: String
    var kind: String     // "stdio" | "http" | "sse"
    var command: String  // stdio
    var args: String     // stdio, quote-aware space-joined (see joinArgs/splitArgs)
    var url: String      // http / sse

    static func == (lhs: MCPEdit, rhs: MCPEdit) -> Bool {
        lhs.name == rhs.name && lhs.kind == rhs.kind &&
        lhs.command == rhs.command && lhs.args == rhs.args && lhs.url == rhs.url
    }

    /// Args array → display string. Quotes any arg containing whitespace so
    /// splitArgs can round-trip it losslessly (e.g. a path with spaces).
    static func joinArgs(_ args: [String]) -> String {
        args.map { arg in
            arg.isEmpty || arg.contains(" ") || arg.contains("\t") ? "\"\(arg)\"" : arg
        }
        .joined(separator: " ")
    }

    /// Display string → args array, honoring "..." and '...' quoting.
    /// Escaped quotes inside quotes are not supported — config args don't need them.
    static func splitArgs(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var sawQuote = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                sawQuote = true
            } else if ch == " " || ch == "\t" {
                if sawQuote || !current.isEmpty { result.append(current) }
                current = ""
                sawQuote = false
            } else {
                current.append(ch)
            }
        }
        if sawQuote || !current.isEmpty { result.append(current) }
        return result
    }
}

/// Editable model for `~/.claude.json` mcpServers. This file is written by Claude Code
/// at runtime, so the stale-guard is essential; saves preserve every other key (projects,
/// history, …) and every untouched per-server field (env, headers, …).
@MainActor
final class MCPStore: ObservableObject, GuardedStore {
    @Published var servers: [MCPEdit] = []
    @Published var statusMessage: String?
    @Published var isError = false
    @Published var isStale = false
    @Published var canRestore = false

    private var root: [String: Any] = [:]
    private var originalServers: [String: Any] = [:]
    private var origServers: [MCPEdit] = []
    private var loadedHash = ""
    private let fileURL: URL
    private let guardian: WriteGuard
    private var watcher: FileWatcher?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileURL = home.appending(path: ".claude.json")
        let claude = home.appending(path: ".claude")
        self.guardian = WriteGuard(fileURL: fileURL, backupDir: claude.appending(path: "backups"))
        load()
        watcher = FileWatcher(url: fileURL) { [weak self] in self?.externalChange() }
    }

    /// ~/.claude.json is rewritten by Claude Code at runtime, so this fires often:
    /// our own writes are filtered by hash; clean state reloads silently, dirty
    /// state raises the stale banner instead of clobbering the user's edits.
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

    var hasChanges: Bool { servers != origServers }

    func load() {
        isStale = false
        isError = false
        statusMessage = nil
        guard let data = try? Data(contentsOf: fileURL.resolvingSymlinksInPath()) else {
            // No ~/.claude.json yet (Claude Code not run on this machine). First Save creates it.
            statusMessage = String(localized: "~/.claude.json doesn't exist yet — it will be created on first save.")
            root = [:]
            loadedHash = ""
            originalServers = [:]
            servers = []
            origServers = []
            canRestore = !guardian.backups().isEmpty
            return
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            isError = true
            statusMessage = String(localized: "~/.claude.json is not valid JSON — fix it externally or restore a backup.")
            return
        }
        root = dict
        loadedHash = WriteGuard.hash(data)
        originalServers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers = originalServers.map { name, value in
            let cfg = value as? [String: Any] ?? [:]
            if let url = cfg["url"] as? String {
                return MCPEdit(originalName: name, name: name, kind: (cfg["type"] as? String) ?? "http",
                               command: "", args: "", url: url)
            }
            let args = MCPEdit.joinArgs(cfg["args"] as? [String] ?? [])
            return MCPEdit(originalName: name, name: name, kind: "stdio",
                           command: (cfg["command"] as? String) ?? "", args: args, url: "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        origServers = servers
        canRestore = !guardian.backups().isEmpty
    }

    func add() {
        servers.append(MCPEdit(originalName: nil, name: "new-server", kind: "stdio", command: "", args: "", url: ""))
    }

    func remove(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
    }

    func discard() {
        servers = origServers
        isError = false
        statusMessage = nil
    }

    func save() {
        isError = false
        statusMessage = nil
        let names = servers.map { $0.name.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: \.isEmpty) { fail(String(localized: "Empty server name not allowed")); return }
        if Set(names).count != names.count { fail(String(localized: "Duplicate server name not allowed")); return }

        var rebuilt: [String: Any] = [:]
        for e in servers {
            // preserve untouched per-server keys (env, headers, …) — keyed by the
            // load-time name so a rename doesn't orphan them
            var sub = originalServers[e.originalName ?? e.name] as? [String: Any] ?? [:]
            if e.kind == "stdio" {
                sub["command"] = e.command
                sub["args"] = MCPEdit.splitArgs(e.args)
                sub["url"] = nil
                sub["type"] = nil
            } else {
                sub["url"] = e.url
                sub["type"] = e.kind
                sub["command"] = nil
                sub["args"] = nil
            }
            rebuilt[e.name] = sub
        }
        var merged = root
        merged["mcpServers"] = rebuilt
        // Compact (no pretty/sorted) to match ~/.claude.json's runtime style.
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.withoutEscapingSlashes]) else {
            fail(String(localized: "Serialization failed"))
            return
        }
        do {
            try guardian.commit(data, expectedHash: loadedHash)
            root = merged
            originalServers = rebuilt
            loadedHash = WriteGuard.hash(data)
            // rebuilt is keyed by the saved names — realign so the next save's lookup hits
            for i in servers.indices { servers[i].originalName = servers[i].name }
            origServers = servers
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
