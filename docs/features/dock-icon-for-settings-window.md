# Feature — Dock Icon for Settings Window

Last verified: 2026-08-13

Status: implemented
Source of truth: yes

## Summary

- Settings open → MacTools appears in the Dock.
- Settings close → MacTools returns to menu-bar-only mode.

## User flow

- The user opens MacTools Settings.
- MacTools becomes a regular app and its Dock icon appears.
- The user closes Settings.
- MacTools returns to accessory mode; its Dock icon disappears.

## Business rules

| Rule | Markdown | Central code | Consumption |
|---|---|---|---|
| No durable business rule | — | — | — |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-13 | Only Settings controls Dock presence | It is MacTools’s persistent AppKit window; menu-bar panels remain transient | Open Settings shows the icon; closing Settings hides it |

## Plan

- [x] P001 — Define the Dock visibility lifecycle.
- [x] P002 — Switch activation policy with the Settings window lifecycle.
- [x] P003 — Add targeted coverage and release note.

## TODO

- [x] F001 — Define acceptance contract — files: `docs/user-stories/app/dock-icon-for-settings-window.md` — status: done
- [x] F002 — Manage activation policy — files: `Sources/App/AppWindowRouter.swift` — status: done
- [x] F003 — Cover visibility policy — files: `Tests/App/AppWindowRouterTests.swift` — status: done

## Codex implementation journal

- 2026-08-13 — `AppWindowRouter` selects `.regular` before presenting Settings and restores `.accessory` after its close. `AppDockVisibilityPolicy` makes the lifecycle decision unit-testable. User-story validation and `AppWindowRouterTests` passed; the test build emits pre-existing DiskClean Swift 6 concurrency warnings outside this change.

## Current files

| Area | Files |
|---|---|
| Window lifecycle | `Sources/App/AppWindowRouter.swift` |
| Tests | `Tests/App/AppWindowRouterTests.swift` |
| User story | `docs/user-stories/app/dock-icon-for-settings-window.md` |

## Tests / QA

- [x] Opening Settings selects `.regular` activation policy.
- [x] Closing Settings selects `.accessory` activation policy.

## History

<!-- Read only for a bug, regression, audit, or explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
