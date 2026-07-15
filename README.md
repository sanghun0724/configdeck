<p align="center">
  <img src="docs/icon-1024.png" width="128" alt="ConfigDeck icon" />
</p>

# ConfigDeck

[![CI](https://github.com/sanghun0724/configdeck/actions/workflows/ci.yml/badge.svg)](https://github.com/sanghun0724/configdeck/actions/workflows/ci.yml)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/sh_brady)

**English** | [한국어](README.ko.md)

A native macOS (SwiftUI) app that shows your scattered `~/.claude` configuration
**at a glance**. Skills, agents, settings, hooks, MCP servers, and slash commands —
all in one structured, searchable window.

> Built for Claude Code users who can't easily see *"what have I actually configured?"*
> across dozens of files. Read-first design: browsing never touches your files, and
> every edit goes through an explicit Save with a backup taken first.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" width="820" alt="ConfigDeck — Skills section with detail view" />
  </picture>
</p>

## Why

Claude Code config lives across many files and directories (`skills/`, `agents/`,
`settings.json`, `~/.claude.json`, `commands/`, …). Editing a single file is easy;
*seeing the whole picture* is not. This dashboard gives you one place to inventory
everything you've set up.

## Features (v1)

<p align="center">
  <img src="docs/demo.gif" width="820" alt="Demo — filter skills with search, open the markdown editor, browse Agents, Hooks and Settings" />
</p>
<p align="center"><sub>Search skills → markdown editor with frontmatter highlighting → Agents · Hooks · Settings</sub></p>

| Section | Shows | Editing |
|---------|-------|---------|
| **Skills** | name, description, level, argument hint | full markdown editor + create new |
| **Agents** | model and tool restrictions | full markdown editor + create new |
| **Commands** | slash commands (files + namespaced folders) | full markdown editor + create new |
| **MCP Servers** | servers from `~/.claude.json` | add / delete / edit (command, args, url) |
| **Hooks** | events, matchers, commands from `settings.json` | add / delete |
| **Settings** | permission rules (allow / ask / deny) + env vars | inline edit |

- Search/filter in every section (`⌘K` focuses the search field)
- Follows symlinks (e.g. `~/.claude/skills` → external config repo)
- Watches files for external changes — if Claude Code rewrites `~/.claude.json`
  while you're looking at it, the app reloads (or warns instead of clobbering
  your unsaved edits)
- UI language: System / English / 한국어 / Español / 中文 / 日本語
  (Settings → Language, requires a restart to apply)

## Safety model

The app is **read-first**: nothing is written until you explicitly hit Save.
Every write goes through the same guarded path:

1. **Backup first** — the on-disk version is copied to `~/.claude/backups`
   (20 most recent kept per file; Restore lets you pick any of them).
2. **Stale-guard** — if the file changed on disk since it was loaded, the save
   is rejected instead of overwriting someone else's change.
3. **Atomic write** — the new content replaces the file in one step; a crash
   can't leave a half-written config.
4. **Preserve unknown keys** — JSON keys and per-server fields the app doesn't
   model (env, headers, projects, history, …) survive every save untouched.

See [`DESIGN-writeback.md`](DESIGN-writeback.md) for the full write-back design.

The app runs **unsandboxed** so it can read `~/.claude` and `~/.claude.json` —
this means it has the same filesystem access as any other process you run as
your user. Review the source before running a build you didn't compile yourself.

## Install

### Quick install (no Gatekeeper popup)

```sh
curl -fsSL https://raw.githubusercontent.com/sanghun0724/configdeck/main/install.sh | sh
```

Downloads the latest release and installs it to `/Applications`. The app is
not notarized yet ([why the popup happens](#not-notarized)) — curl-based
downloads carry no quarantine flag, so this path skips the popup entirely.
[Read the script](install.sh) first if you like; it's ~50 lines.

### Homebrew

```sh
brew install --cask sanghun0724/tap/configdeck
xattr -cr /Applications/ConfigDeck.app   # clear the Gatekeeper quarantine flag
```

### Download

Grab the latest `.zip` from [Releases](https://github.com/sanghun0724/configdeck/releases),
unzip, and drag `ConfigDeck.app` to Applications.

<a name="not-notarized"></a>
Homebrew and browser downloads are quarantined, and ConfigDeck is not
notarized yet, so on first launch macOS will block it. Either run
`xattr -cr /Applications/ConfigDeck.app`, or open
**System Settings → Privacy & Security** and click **Open Anyway**
(on macOS 14 you can also right-click the app → **Open** → **Open**).

### Build from source

Requires macOS 14+, Xcode 15+, and [`xcodegen`](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open ConfigDeck.xcodeproj
# ⌘R to run, or:
xcodebuild -scheme ConfigDeck -configuration Debug build
```

The app reads from `~/.claude` and `~/.claude.json` in your home directory.
If you don't use Claude Code yet, sections will be empty — `settings.json`
and `~/.claude.json` are created on your first save.

## Roadmap

- ✅ Safe editing across all sections (permissions, env, hooks, MCP, markdown files)
- ✅ Search everywhere, file watching, backup picker, create-new scaffolds
- Structured frontmatter forms for skills/agents (currently raw markdown)
- Sharing / discovery of skills between teammates
- Live session & cache inspection

## Contributing

Small project, simple rules — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

If you find ConfigDeck useful, consider buying me a coffee!

<a href="https://buymeacoffee.com/sh_brady" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" width="200"></a>

## License

MIT — see [LICENSE](LICENSE).
