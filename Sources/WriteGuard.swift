import Foundation
import CryptoKit

enum WriteGuardError: Error, LocalizedError {
    case staleFile
    case noBackup
    var errorDescription: String? {
        switch self {
        case .staleFile: return String(localized: "settings.json changed on disk since load. Reload before saving.")
        case .noBackup: return String(localized: "No backup available to restore.")
        }
    }
}

/// File-level write safety: stale-guard (#5), backup-first (#1), atomic write (#2), rollback (#7).
struct WriteGuard {
    let fileURL: URL
    let backupDir: URL
    let maxBackups: Int

    init(fileURL: URL, backupDir: URL, maxBackups: Int = 20) {
        self.fileURL = fileURL.resolvingSymlinksInPath()
        self.backupDir = backupDir
        self.maxBackups = maxBackups
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic write gated by stale check; backs up the on-disk version first.
    func commit(_ newData: Data, expectedHash: String) throws {
        guard let onDisk = try? Data(contentsOf: fileURL) else {
            // No file on disk — either it never existed (fresh install) or it was
            // deleted externally while editing. Nothing to protect or back up:
            // create it so the user's work isn't trapped in the editor.
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newData.write(to: fileURL, options: .atomic)
            return
        }
        guard Self.hash(onDisk) == expectedHash else { throw WriteGuardError.staleFile }
        try backup(onDisk)
        try newData.write(to: fileURL, options: .atomic)
        pruneBackups()
    }

    /// Back up the file, then delete it. The backup makes the delete recoverable.
    func deleteWithBackup() throws {
        let data = try Data(contentsOf: fileURL)
        try backup(data)
        try FileManager.default.removeItem(at: fileURL)
        pruneBackups()
    }

    /// Restore newest backup (itself backs up the current file first).
    func restoreLatest(expectedHash: String) throws {
        guard let latest = backups().first else { throw WriteGuardError.noBackup }
        try restore(from: latest, expectedHash: expectedHash)
    }

    /// Restore a specific backup (itself backs up the current file first).
    func restore(from backup: URL, expectedHash: String) throws {
        let data = try Data(contentsOf: backup)
        try commit(data, expectedHash: expectedHash)
    }

    func backups() -> [URL] {
        let prefix = backupPrefix + "."
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil)) ?? []
        // ISO-8601 timestamp in the name sorts lexically == chronologically.
        return items
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "bak" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Backups are pooled in one dir but namespaced by a path hash, so many same-named
    /// files (e.g. dozens of `SKILL.md`) never collide or cross-restore.
    private var backupPrefix: String {
        let id = SHA256.hash(data: Data(fileURL.path.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(id)-\(fileURL.lastPathComponent)"
    }

    private func backup(_ data: Data) throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(backupPrefix).\(stamp).bak"
        try data.write(to: backupDir.appending(path: name), options: .atomic)
    }

    private func pruneBackups() {
        let all = backups()
        guard all.count > maxBackups else { return }
        for url in all.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
