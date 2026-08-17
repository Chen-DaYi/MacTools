# Changelog Fragments

Pending app and plugin release notes live in `changes/unreleased/*.md`. Each
markdown file is consumed by the next matching release, merged into
`CHANGELOG.md`, and deleted in the release commit.

`CHANGELOG.md` is the canonical history. The release helper also regenerates
`Sources/Resources/ReleaseHistory.json` for the scrollable, offline history in
About. Do not edit the generated JSON by hand; run
`python3 scripts/changelog.py export-history` after repairing historical notes.

Use short English, user-facing entries. Avoid implementation details, duplicate
phrasing, and long multi-clause bullets.

```markdown
---
release: app
type: fixed
area: Finder Integration
---

Finder right-click menu items now stay hidden when the plugin is disabled.
```

Use `release: app` for app releases and `release: plugin` for plugin batch
releases. Valid `type` values are `summary`, `added`, `changed`, `deprecated`,
`removed`, `fixed`, `security`, and `maintenance`.

If one change affects both release channels, add two fragments: one `release:
app` entry that describes the host/app impact, and one `release: plugin` entry
that describes the plugin-package impact. Do not copy the same sentence into
both files.
