# Contributing

Thanks for taking a look. This is a small, focused project — the bar for a good
PR is low ceremony, high clarity.

## Setup

```sh
brew install xcodegen
xcodegen generate
open ClaudeConfigDashboard.xcodeproj
```

The Xcode project is generated — never commit `ClaudeConfigDashboard.xcodeproj`
(it's gitignored). If you add/remove files, re-run `xcodegen generate`.

## Before you open a PR

- `xcodebuild -scheme ClaudeConfigDashboard build` passes with no warnings.
- `xcodebuild -scheme ClaudeConfigDashboard test` passes.
- Anything touching the write path (WriteGuard, stores, serializers) comes
  with a test. The whole point of this app is not eating people's config.
- New user-facing strings go into `Sources/Localizable.xcstrings` with
  translations for ko / es / zh-Hans / ja (machine translation is fine,
  mark it in the PR).

## Design notes

- Read-first: browsing never writes. Every write goes through `WriteGuard`
  (backup → stale-guard → atomic write). See `DESIGN-writeback.md`.
- Preserve-unknown-keys is a hard invariant: saving must never drop JSON the
  app doesn't model.
