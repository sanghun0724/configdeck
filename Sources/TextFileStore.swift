import Foundation
import SwiftUI

/// Live editor for a single text file (markdown skill/agent/command bodies),
/// guarded by WriteGuard: backup-first, atomic write, stale-guard, restore.
@MainActor
final class TextFileStore: ObservableObject, GuardedStore {
    @Published var text = ""
    @Published var statusMessage: String?
    @Published var isError = false
    @Published var isStale = false
    @Published var canRestore = false
    /// SwiftUI's TextEditor degrades on very large documents — the editor shows a
    /// heads-up banner instead of silently lagging.
    @Published var isLarge = false

    private var loadedHash = ""
    private var origText = ""
    private let fileURL: URL
    private let guardian: WriteGuard
    private var watcher: FileWatcher?

    init(path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        self.fileURL = url
        // Backups live under ~/.claude/backups even for symlinked external files,
        // so we never write extra files into an external config repo.
        let claude = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        self.guardian = WriteGuard(fileURL: url, backupDir: claude.appending(path: "backups"))
        load()
        watcher = FileWatcher(url: url) { [weak self] in self?.externalChange() }
    }

    /// External change detected by the watcher: our own writes are filtered by hash;
    /// clean state reloads silently, dirty state raises the stale banner instead of
    /// clobbering the user's edits.
    private func externalChange() {
        guard let data = try? Data(contentsOf: fileURL) else {
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

    var hasChanges: Bool { text != origText }

    func load() {
        isStale = false
        isError = false
        statusMessage = nil
        guard let data = try? Data(contentsOf: fileURL) else {
            isError = true
            statusMessage = String(localized: "File not readable")
            return
        }
        text = String(decoding: data, as: UTF8.self)
        origText = text
        loadedHash = WriteGuard.hash(data)
        isLarge = data.count > 500_000
        canRestore = !guardian.backups().isEmpty
    }

    func discard() {
        text = origText
        isError = false
        statusMessage = nil
    }

    func save() {
        isError = false
        statusMessage = nil
        do {
            try guardian.commit(Data(text.utf8), expectedHash: loadedHash)
            origText = text
            loadedHash = WriteGuard.hash(Data(text.utf8))
            canRestore = true
            statusMessage = String(localized: "Saved — backup created.")
        } catch let error as WriteGuardError where error == .staleFile {
            isStale = true
            fail(error.localizedDescription)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Back up then delete the file. Returns true on success.
    func delete() -> Bool {
        do {
            try guardian.deleteWithBackup()
            return true
        } catch {
            fail(error.localizedDescription)
            return false
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
