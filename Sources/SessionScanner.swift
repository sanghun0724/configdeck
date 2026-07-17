import Foundation

/// One project directory under `~/.claude/projects`, with its session transcripts.
struct SessionProject: Identifiable {
    var id: String { dirPath }
    let dirPath: String
    /// Real project path recovered from the newest transcript's `cwd` — the directory
    /// name itself is a lossy encoding (`/` and `.` both become `-`).
    let displayPath: String
    /// Newest first.
    var sessions: [SessionSummary]
}

/// Listing metadata for one transcript file — file attributes only, no content read.
struct SessionSummary: Identifiable {
    var id: String { path }
    let path: String
    let sessionId: String
    let projectDisplayPath: String
    let modified: Date
    let sizeBytes: Int
}

/// Read-only scanner for `~/.claude/projects`. Listing never reads transcript
/// bodies; per-session titles are fetched lazily via `title(for:)` as rows become
/// visible. No watcher, no writer — browsing must never touch these files.
struct SessionScanner {
    let home: URL
    private let fm = FileManager.default

    /// Bounded reads: titles usually sit near the end (ai-title) or the start
    /// (first prompt), so 64KB/256KB windows cover them without loading the file.
    private static let tailWindow = 64 * 1024
    private static let headWindow = 256 * 1024

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var projectsDir: URL { home.appending(path: ".claude/projects") }

    // MARK: - Listing

    func scan() -> [SessionProject] {
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var projects: [SessionProject] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let sessions = sessionFiles(in: dir)
            guard !sessions.isEmpty else { continue }
            let displayPath = headCwd(of: sessions[0].path) ?? dir.lastPathComponent
            projects.append(SessionProject(
                dirPath: dir.path,
                displayPath: displayPath,
                sessions: sessions.map {
                    SessionSummary(
                        path: $0.path,
                        sessionId: URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent,
                        projectDisplayPath: displayPath,
                        modified: $0.modified,
                        sizeBytes: $0.size
                    )
                }
            ))
        }
        return projects.sorted { ($0.sessions.first?.modified ?? .distantPast) > ($1.sessions.first?.modified ?? .distantPast) }
    }

    /// Non-recursive: project dirs also hold UUID subdirectories (subagent
    /// transcripts) and index files — only top-level `.jsonl` are sessions.
    private func sessionFiles(in dir: URL) -> [(path: String, modified: Date, size: Int)] {
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (path: String, modified: Date, size: Int) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return (url.path, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
    }

    // MARK: - Lazy title

    /// Best-effort session title: last `ai-title` from the tail window, else the
    /// first human prompt from the head window, else nil (row shows the session id).
    func title(for path: String) -> String? {
        if let title = tailTitle(of: path) { return title }
        return headPrompt(of: path)
    }

    private func tailTitle(of path: String) -> String? {
        for line in tailLines(of: path).reversed() where line.contains("\"ai-title\"") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               object["type"] as? String == "ai-title",
               let title = object["aiTitle"] as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private func headPrompt(of path: String) -> String? {
        for line in headLines(of: path) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? String else { continue }
            let prompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Local-command echoes arrive as XML-tagged user entries — not a title.
            guard !prompt.isEmpty, !prompt.hasPrefix("<") else { continue }
            let firstLine = prompt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(firstLine.prefix(100))
        }
        return nil
    }

    /// First `cwd` value in the head window — recovers the real project path.
    private func headCwd(of path: String) -> String? {
        for line in headLines(of: path) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cwd = object["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }

    // MARK: - Bounded file windows

    private func headLines(of path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: Self.headWindow) else { return [] }
        defer { try? handle.close() }
        var lines = decodedLines(of: data)
        // The window likely cuts the last line mid-JSON — drop it.
        if data.count == Self.headWindow, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    private func tailLines(of path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path),
              let size = try? handle.seekToEnd() else { return [] }
        defer { try? handle.close() }
        let offset = size > UInt64(Self.tailWindow) ? size - UInt64(Self.tailWindow) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd() else { return [] }
        if offset > 0 {
            // The seek can land mid-line — and mid-way through a multibyte UTF-8
            // character, which would nil out the whole decode. Realign to the
            // first newline so every kept byte starts on a line boundary.
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = data[data.index(after: newline)...]
        }
        return decodedLines(of: Data(data))
    }

    private func decodedLines(of data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
