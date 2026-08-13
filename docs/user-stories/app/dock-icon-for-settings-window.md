# US-app-dock-icon-for-settings-window — Dock Icon for Settings

Last verified: 2026-08-13

| Field | Value |
| --- | --- |
| ID | `US-app-dock-icon-for-settings-window` |
| Status | `implemented` |
| Domain | `app` |
| Actor | `MacTools user` |

## User Story

> As a MacTools user, when the Settings window is open, I want to see the MacTools icon in the Dock so that I can identify and return to the active app.

## Acceptance

- Given MacTools runs as a menu-bar app
- When the user opens Settings
- Then the app uses the `.regular` activation policy and appears in the Dock
- And closing Settings restores `.accessory`; menu-bar panels do not affect Dock visibility

## References

| Type | Source |
| --- | --- |
| Feature | `docs/features/dock-icon-for-settings-window.md` |
| Code | `Sources/App/AppWindowRouter.swift` |
| Test | `Tests/App/AppWindowRouterTests.swift` |

## History

| Date | Type | Previous | New | Source |
| --- | --- | --- | --- |
| 2026-08-13 | created | — | Initial contract | User prompt |
| 2026-08-13 | implementation | `draft` | `implemented` | `Sources/App/AppWindowRouter.swift` |
