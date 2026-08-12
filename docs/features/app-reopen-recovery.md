# Feature — App Reopen Recovery

Last verified: 2026-08-12

Status: planned — WIP unsafe, not mergeable
Source of truth: yes

## Summary

- The AppKit reopen callback presents Settings.
- The Debug polling fallback is invalid: two runtimes can remain active.
- Target: one instance; secondary copy → `show-settings` command → terminate before bootstrap.

## User flow

- MacTools is already running without a visible window, or with an existing window.
- The user launches the app again from Finder, Spotlight, or the Dock.
- The MacTools Settings window is shown and activated.
- If a launcher starts another copy, it sends the request and terminates.
- Only one runtime remains active.

## Business rules

| Rule | Markdown | Central code | Consumption |
|---|---|---|---|
| No durable business rule | — | — | — |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-12 | Reopen → Settings | Recovery independent of the menu-bar icon | The AppKit callback remains in place |
| 2026-08-12 | Single instance + acknowledged IPC | Avoid competing runtimes | The secondary copy sends the request and terminates before bootstrap |

## Plan

- [x] P001 — Define the recovery scenario.
- [x] P002 — Handle AppKit reopen.
- [x] P003 — Add tests, changelog, and Draft PR.
- [x] P004 — Reproduce the launcher case with two processes.
- [x] P005 — Diagnose the risk and write the architecture plan.
- [ ] P006 — Replace polling with single-instance coordination and IPC.
- [ ] P007 — Certify with multi-process tests and real QA.

## TODO

- [x] F001 — Define the recovery surface — files: `docs/features/app-reopen-recovery.md` — status: done
- [x] F002 — Show Settings on reopen — files: `Sources/App/MacToolsApp.swift` — status: done
- [x] F003 — Cover the AppKit callback — files: `Tests/App/MacToolsAppDelegateTests.swift` — status: done
- [ ] F004 — Guarantee one runtime — files: `Sources/App/AppInstanceCoordinator.swift`, `Sources/App/MacToolsAppRuntime.swift` — status: planned
- [ ] F005 — Cover races, crashes, ACKs, and timeouts — files: `Tests/App/AppInstanceCoordinatorTests.swift`, `Tests/App/AppInstanceCoordinatorProcessTests.swift` — status: planned

## Codex implementation journal

- 2026-08-12 — `MacToolsAppDelegate.applicationShouldHandleReopen` delegates to `AppWindowRouter.showSettings()` with either visibility state and returns `false` because the app handles the AppKit event itself. `MacToolsAppDelegateTests` covers this wiring; `AppWindowRouterTests` covers activation, deminiaturization, and ordering front.
- 2026-08-12 — In Debug, the instance scans running applications once per second; launching another copy with the same bundle ID opens Settings in the existing instance once per PID. Bundle ID and PID filtering tests were added.
- 2026-08-12 — Real validation: `make run` launches the repository bundle, then opening a competing Xcode copy presents Settings in the existing instance. The capture was visually checked.
- 2026-08-12 — Diagnostic correction: QA shows that two processes remain active. Polling is symmetric; it guarantees neither which instance presents Settings nor runtime uniqueness.
- 2026-08-12 — Replacement plan: `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md`. The PR remains Draft; it must not become Ready before multi-process evidence exists.

## Current files

| Area | Files |
|---|---|
| App lifecycle | `Sources/App/MacToolsApp.swift` |
| Architecture plan | `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md` |
| Settings presentation | `Sources/App/AppWindowRouter.swift` |
| Tests | `Tests/App/MacToolsAppDelegateTests.swift`, `Tests/App/AppWindowRouterTests.swift` |

## Tests / QA

- [x] The AppKit callback requests Settings; the router activates, deminiaturizes, and orders the window front.
- [x] Run `MacToolsAppDelegateTests` and `AppWindowRouterTests` after implementation.
- [x] Reproduce two competing Debug bundles: Settings is shown, but two processes remain active.
- [ ] Verify that a secondary copy terminates without initializing the runtime.
- [ ] Verify ten concurrent launches, primary crash, and timeout.
- [ ] Repeat Finder, Spotlight, Dock, and launcher QA with one final process.

## History

<!-- Read only for a bug, regression, audit, or explicit request. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-12 | `vwt` | Feature | MacTools reopen as a recovery path |
