import Foundation

/// One cleanup suggestion returned by the `claude` CLI. The model judges the inventory
/// freely — these fields are the agreed shape it serializes back.
struct CleanupSuggestion: Identifiable, Decodable {
    var id = UUID()
    let title: String
    let rationale: String
    let severity: String          // "high" | "medium" | "low"
    let paths: [String]           // target file paths (may be empty for advisory notes)
    let action: String            // "delete" | "edit" | "review" | "note"

    private enum CodingKeys: String, CodingKey { case title, rationale, severity, paths, action }
}

/// Thread-safe stdout accumulator for the concurrent pipe drain.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

enum ClaudeServiceError: LocalizedError {
    case notFound
    case badOutput(String)
    case cliError(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "The `claude` CLI wasn't found in the usual locations.")
        case .badOutput(let s):
            return String(localized: "Couldn't read the CLI response.\n\(String(s.prefix(300)))")
        case .cliError(let s):
            return s
        }
    }
}

/// Bridges to the user's installed Claude Code CLI in headless mode (`claude -p`).
/// Uses the existing CLI auth — no API key handling. One-shot calls for analysis;
/// `--resume <session_id>` threads a chat so context persists CLI-side.
@MainActor
final class ClaudeService {
    let binaryPath: String?

    init() { binaryPath = Self.locate() }

    var isAvailable: Bool { binaryPath != nil }

    private static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Reply {
        let text: String
        let sessionId: String?
    }

    /// Run a single headless prompt. `resume` continues a prior chat session.
    func run(prompt: String, resume: String? = nil, model: String = "sonnet") async throws -> Reply {
        guard let bin = binaryPath else { throw ClaudeServiceError.notFound }
        var args = ["-p", prompt, "--output-format", "json", "--model", model]
        if let resume { args += ["--resume", resume] }

        let raw = try await Self.exec(bin: bin, args: args)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeServiceError.badOutput(raw)
        }
        if (obj["is_error"] as? Bool) == true {
            throw ClaudeServiceError.cliError(obj["result"] as? String ?? "CLI reported an error.")
        }
        return Reply(text: obj["result"] as? String ?? "", sessionId: obj["session_id"] as? String)
    }

    /// Spawn the CLI, draining stdout concurrently so large JSON can't deadlock the pipe.
    private static func exec(bin: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = args

            // GUI apps don't inherit a shell PATH; give the node-backed CLI one.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let collector = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                collector.append(chunk)
            }

            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                let text = String(decoding: collector.snapshot(), as: UTF8.self)
                if text.isEmpty {
                    let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(throwing: ClaudeServiceError.badOutput(errText.isEmpty ? "No output." : errText))
                } else {
                    cont.resume(returning: text)
                }
            }

            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
