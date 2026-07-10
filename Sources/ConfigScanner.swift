import Foundation

/// Reads the user's Claude config from `~/.claude` (and `~/.claude.json`) read-only.
/// All directory entries are resolved through symlinks because `~/.claude/skills`
/// (etc.) are commonly symlinked to an external config repo.
struct ConfigScanner {
    let home: URL
    private let fm = FileManager.default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var claudeDir: URL { home.appending(path: ".claude") }

    func scan() -> ConfigData {
        var data = ConfigData()
        data.claudeDir = claudeDir.path
        data.skills = scanSkills(&data.errors)
        data.agents = scanAgents(&data.errors)
        data.commands = scanCommands(&data.errors)
        data.mcpServers = scanMCPServers(&data.errors)
        scanSettings(into: &data)
        return data
    }

    // MARK: - Directory helper

    private func entries(of dir: URL) -> [URL] {
        let resolved = dir.resolvingSymlinksInPath()
        guard let items = try? fm.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: - Skills

    private func scanSkills(_ errors: inout [String]) -> [Skill] {
        var skills: [Skill] = []
        for dir in entries(of: claudeDir.appending(path: "skills")) where isDirectory(dir) {
            let skillFile = dir.appending(path: "SKILL.md")
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            let fm = FrontmatterParser.parse(content)
            let tools = (fm["allowed-tools"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let modified = (try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            skills.append(Skill(
                name: fm["name"] ?? dir.lastPathComponent,
                description: fm["description"] ?? "",
                argumentHint: fm["argument-hint"],
                level: fm["level"],
                tools: tools,
                modified: modified,
                path: skillFile.path
            ))
        }
        return skills
    }

    // MARK: - Agents

    private func scanAgents(_ errors: inout [String]) -> [Agent] {
        var agents: [Agent] = []
        for file in entries(of: claudeDir.appending(path: "agents")) where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fm = FrontmatterParser.parse(content)
            agents.append(Agent(
                name: fm["name"] ?? file.deletingPathExtension().lastPathComponent,
                description: fm["description"] ?? "",
                model: fm["model"],
                level: fm["level"],
                disallowedTools: fm["disallowedTools"] ?? fm["tools"],
                path: file.path
            ))
        }
        return agents
    }

    // MARK: - Commands

    /// Recurses into namespace subdirectories (e.g. `commands/git/commit.md`) instead
    /// of listing the folder itself, so every command is an openable file — Claude
    /// Code invokes these as `/git:commit`, so nested names join with ":" to match.
    private func scanCommands(_ errors: inout [String]) -> [Command] {
        scanCommandDir(claudeDir.appending(path: "commands"), namespace: nil, depth: 0)
    }

    private func scanCommandDir(_ dir: URL, namespace: String?, depth: Int) -> [Command] {
        // Depth cap guards against symlink cycles (entries() follows symlinks).
        guard depth < 10 else { return [] }
        var commands: [Command] = []
        for item in entries(of: dir) {
            if isDirectory(item) {
                let ns = namespace.map { "\($0):\(item.lastPathComponent)" } ?? item.lastPathComponent
                commands += scanCommandDir(item, namespace: ns, depth: depth + 1)
            } else if item.pathExtension == "md" {
                let name = item.deletingPathExtension().lastPathComponent
                commands.append(Command(
                    name: namespace.map { "\($0):\(name)" } ?? name,
                    kind: "file",
                    path: item.path
                ))
            }
        }
        return commands
    }

    // MARK: - MCP servers (from ~/.claude.json)

    private func scanMCPServers(_ errors: inout [String]) -> [MCPServer] {
        let url = home.appending(path: ".claude.json")
        guard let raw = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return [] }

        var result: [MCPServer] = []
        for (name, value) in servers {
            guard let cfg = value as? [String: Any] else { continue }
            if let url = cfg["url"] as? String {
                let kind = (cfg["type"] as? String) ?? "http"
                result.append(MCPServer(name: name, detail: url, kind: kind))
            } else {
                let command = (cfg["command"] as? String) ?? ""
                let args = (cfg["args"] as? [String]) ?? []
                let line = ([command] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                result.append(MCPServer(name: name, detail: line, kind: "stdio"))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Settings (permissions, env, hooks)

    private func scanSettings(into data: inout ConfigData) {
        let url = claudeDir.appending(path: "settings.json")
        guard let raw = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            data.errors.append("settings.json not found or invalid")
            return
        }

        if let permissions = json["permissions"] as? [String: Any] {
            data.allow = (permissions["allow"] as? [String] ?? []).map { PermissionRule(value: $0) }
            data.deny = (permissions["deny"] as? [String] ?? []).map { PermissionRule(value: $0) }
            data.ask = (permissions["ask"] as? [String] ?? []).map { PermissionRule(value: $0) }
        }

        if let env = json["env"] as? [String: Any] {
            data.envVars = env
                .map { EnvVar(key: $0.key, value: String(describing: $0.value)) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }

        if let hooks = json["hooks"] as? [String: Any] {
            var entries: [HookEntry] = []
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                for group in groups {
                    let matcher = (group["matcher"] as? String) ?? "*"
                    let commands = (group["hooks"] as? [[String: Any]] ?? [])
                        .compactMap { $0["command"] as? String }
                    entries.append(HookEntry(event: event, matcher: matcher, commands: commands))
                }
            }
            data.hooks = entries.sorted {
                $0.event.localizedCaseInsensitiveCompare($1.event) == .orderedAscending
            }
        }
    }
}
