# Claude Config Dashboard

A native macOS (SwiftUI) app that shows your scattered `~/.claude` configuration
**at a glance**. Skills, agents, settings, hooks, MCP servers, and slash commands —
all in one structured, searchable window.

> Built for Claude Code users who can't easily see *"what have I actually configured?"*
> across dozens of files. Read-first: the app never modifies your config.

## Why

Claude Code config lives across many files and directories (`skills/`, `agents/`,
`settings.json`, `~/.claude.json`, `commands/`, …). Editing a single file is easy;
*seeing the whole picture* is not. This dashboard gives you one place to inventory
everything you've set up.

## Features (v1)

| Section | Shows | Editing |
|---------|-------|---------|
| **Skills** | name, description, level, argument hint | full markdown editor |
| **Agents** | model and tool restrictions | full markdown editor |
| **Commands** | slash commands (files + namespaced folders) | full markdown editor (files) |
| **MCP Servers** | servers from `~/.claude.json` | add / delete / edit (command, args, url) |
| **Hooks** | events, matchers, commands from `settings.json` | add / delete |
| **Settings** | permission rules (allow / ask / deny) + env vars | inline edit |

- Searchable Skills and Agents lists
- Follows symlinks (e.g. `~/.claude/skills` → external config repo)
- UI language: System / English / 한국어 / Español / 中文 / 日本語 (Settings → Language, requires a restart to apply)
- **Everything is editable** through one safe write-back model:
  backup-first → atomic write → stale-guard → preserve every other key.
  Explicit Save, Discard, and Restore-from-backup everywhere.
  Skills/agents in an external repo show a warning; `~/.claude.json` shows a
  runtime-volatility warning. See [`DESIGN-writeback.md`](DESIGN-writeback.md).

## Requirements

- macOS 14.0+
- Xcode 15+ (to build) and [`xcodegen`](https://github.com/yonaskolb/XcodeGen)

## Build & Run

```sh
brew install xcodegen
xcodegen generate
open ClaudeConfigDashboard.xcodeproj
# ⌘R to run, or:
xcodebuild -scheme ClaudeConfigDashboard -configuration Debug build
```

The app reads from `~/.claude` and `~/.claude.json` in your home directory.
It runs **unsandboxed** so it can read those paths — this means it has the
same filesystem access as any other process you run as your user, not just
`~/.claude`. Review the source before running a build you didn't compile
yourself.

## Roadmap

- ✅ Safe editing across all sections (permissions, env, hooks, MCP, markdown files)
- Structured frontmatter forms for skills/agents (currently raw markdown)
- Sharing / discovery of skills between teammates
- Live session & cache inspection

## License

MIT — see [LICENSE](LICENSE).
