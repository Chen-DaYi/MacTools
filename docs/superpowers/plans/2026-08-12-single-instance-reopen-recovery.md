# Plan — Single-Instance Settings Recovery

Plan ID: `arch-06ad3254a8a3-scope-caf01c9e2de7`

Date: 2026-08-12

Baseline: `06ad3254a8a3b1dcf3bc8b2e4fb7bee01f6c014a`

PR: [#273 — Draft](https://github.com/ggbond268/MacTools/pull/273)

Architecture status: `ACTION_REQUIRED`

Independent architecture review: `runtime_attestation=gpt-5.6-sol/high`; `settled` packet

## Expected outcome

- One functional instance per bundle ID and user session.
- Finder, Spotlight, Dock, or launcher relaunch: the existing instance shows Settings.
- Secondary copy: send `show-settings`, receive a bounded acknowledgement, then terminate.
- No `PluginHost`, plugin, shortcut, event tap, status item, or updater in the secondary copy.
- Cold launch and login launch remain silent.
- Identical behavior in Debug and Release.
- The PR remains Draft until full certification.

## Confirmed diagnosis

The AppKit reopen callback is correct. The Debug fallback is not:

- it polls `NSWorkspace.runningApplications` every second;
- detection is symmetric: each process sees the other;
- both Settings windows may open;
- two complete runtimes remain active;
- it is Debug-only;
- its PID memory is never purged;
- its tests only exercise a bundle/PID policy, not a multi-process flow.

The main risk is contention over global shortcuts, observers, hardware plugins, preferences, and shared directories.

## Invariants

| ID | Invariant | Expected evidence |
|---|---|---|
| I-001 | At most one functional runtime | Initialization counter = 1 under concurrent launches |
| I-002 | Every secondary copy sends `show-settings` then terminates | ACK received; exit 0; no secondary runtime |
| I-003 | No permanent polling | No `Timer` or `runningApplications` scan |
| I-004 | AppKit reopen and IPC use the same presentation | Same central handler; both entry points tested |
| I-005 | An early command is not lost | `not-ready` response, bounded retry, then ACK after readiness |
| I-006 | Primary crash is recoverable | The next launch becomes primary |
| I-007 | Timeout is bounded and safe | No hang; no second runtime |
| I-008 | Debug and Release share the same code | No `#if DEBUG` around product behavior |

## Evidence ledger

| ID | Evidence | Conclusion |
|---|---|---|
| E-001 | Real reproduction on 2026-08-12: two `MacTools Dev` PIDs remain active | The launcher can start a copy instead of emitting a reopen |
| E-002 | `MacToolsAppDelegate` currently constructs `PluginHost` and stores as properties | Arbitration occurs too late to protect against side effects |
| E-003 | Polling is symmetric and only uses bundle ID plus PID | It cannot nominate the owner instance |
| E-004 | `AppWindowRouter.show` activates, deminiaturizes, and orders the window front | Existing presentation can be reused |
| E-005 | AppKit documents `applicationShouldHandleReopen` for reactivating an already running app | Keep the callback and return `false` after custom handling |
| E-006 | Core Foundation documents named ports, replies, and timeouts | `CFMessagePort` provides the required local IPC without a dependency |
| E-007 | Independent Spec and standards reviews | Polling must not become mergeable |

## Surface classification

| Surface | Classification | Decision |
|---|---|---|
| `applicationShouldHandleReopen` callback | `NON_RISK` | Keep; delegate to the central handler |
| `AppWindowRouter.showSettings()` | `NON_RISK` | Keep; presentation is already tested |
| Debug polling and `AppDuplicateLaunchPolicy` | `ACTION_REQUIRED` | Remove entirely |
| Delegate property initialization | `ACTION_REQUIRED` | Move behind owner election |
| Missing IPC/ACK | `ACTION_REQUIRED` | Add an instance coordinator |
| Silent cold launch | `PRESERVE` | Do not show a window without reopen or IPC command |
| URL routing and plugin bootstrap | `PRESERVE` | Run only in the owner runtime |

## Chosen design

### 1. Atomic owner through `CFMessagePort`

Create `AppInstanceCoordinator`, without an AppKit dependency or persistent state.

- Deterministic port name: `<bundle-id>.instance-coordination.v1`.
- Native user-session namespace.
- `CFMessagePortCreateLocal` attempts atomic registration.
- A newly created port gives role `.primary`.
- An already registered name gives role `.secondary`.
- Attach the callback immediately to a dedicated serial queue.
- Explicitly invalidate at termination.
- On crash, the system invalidates the Mach port; the next copy can become owner.

Do not use `LSMultipleInstancesProhibited` as the primary solution: it cannot transmit `show-settings` and may produce a LaunchServices error instead of the recovery flow.

### 2. Minimal IPC protocol

One versioned command: `show-settings`.

- Envelope: `{version: 1, command: "show-settings", requestID: <UUID>}`.
- Maximum size: 1 KiB.
- Closed responses: `accepted`, `not-ready`, `unsupported`, `invalid`.
- Send timeout: at most 500 ms per attempt.
- Receive timeout: at most 500 ms per attempt.
- Global retry budget: 2 seconds.
- No URL, path, preference, or arbitrary data.
- A secondary copy cannot initialize the runtime, whatever the result.
- `requestID` makes repeated commands idempotent.

Secondary sequence:

1. Detect the existing port.
2. Create the remote port.
3. Send `show-settings` and wait for an ACK.
4. On `accepted`, call `NSApp.terminate(nil)`.
5. On `not-ready`, retry within the 2-second global budget.
6. On invalid port, retry atomic owner election.
7. If it becomes owner after a crash, start normally and request Settings.
8. If an owner remains present without ACK, log and terminate; never initialize a second runtime.

### 3. Create the runtime only for the owner

Introduce `MacToolsAppRuntime`, built after successful election.

It groups:

- `PluginHost`;
- updater and stores;
- `AppWindowRouter`;
- `MenuBarStatusItemController`;
- plugin bootstrap;
- URL router;
- termination cleanup.

Lifecycle:

- `MacToolsAppDelegate` initially owns only the coordinator and lightweight presentation state.
- `applicationWillFinishLaunching` performs election.
- `.secondary` sends then terminates.
- `.primary` allows `applicationDidFinishLaunching` to create `MacToolsAppRuntime`.
- Every delegate callback guards on the role.

### 4. One recovery handler

Replace `showSettingsForReopen` with `requestSettingsRecovery()`.

Inputs:

- AppKit reopen callback;
- `show-settings` IPC command.

States:

- router available: dispatch on the `MainActor`, call `windowRouter.showSettings()`, then reply `accepted`;
- router unavailable: reply `not-ready` while retaining the owner port;
- secondary copy: retry until readiness or 2-second expiry.

Repeated requests after startup remain honored. An already accepted `requestID` must not present a second window.

### 5. Observability

Add `AppLog.instanceCoordination`.

Structured events:

- elected role;
- received command;
- accepted/not-ready/rejected command;
- ACK;
- retry after invalidation;
- timeout;
- secondary termination;
- termination invalidation.

Do not log payloads, personal paths, or sensitive identifiers.

## Failure matrix

| Case | Required behavior |
|---|---|
| First launch | Owner; one runtime; no forced window |
| AppKit reopen | Owner shows and activates Settings |
| Secondary copy, owner ready | Command + ACK; Settings; secondary terminates |
| Secondary copy during bootstrap | `not-ready`; bounded retry; presentation when router exists |
| Two exactly concurrent launches | One local port; one runtime |
| Owner crash before connection | Retry; secondary becomes owner |
| Owner alive but blocked | Timeout; secondary exits without runtime |
| Unknown/invalid message | Reject; no presentation; warning log |
| Debug and Release installed together | Different bundle IDs; independent owners |
| Two copies of the same bundle | One owner |

## Actions and DAG

```text
A-001 Coordinator + IPC protocol
  -> A-002 Runtime gating + shared handler
      -> A-003 Multi-process tests + real QA
          -> A-004 Final review + Draft certification
```

### A-001 — Instance coordinator

Goal: provide atomic election and bounded IPC.

Planned files:

- `Sources/App/AppInstanceCoordinator.swift` — new; role, protocol, `CFMessagePort` transport, timeouts, invalidation.
- `Sources/Core/Diagnostics/AppLog.swift` — dedicated category.
- `Tests/App/AppInstanceCoordinatorTests.swift` — protocol, role, ACK, retry, timeout, invalidation.

Exit contract:

- Typed API: `.primary` or `.secondary(acknowledged: Bool)`.
- No AppKit in the coordinator core.
- Injectable transport for deterministic tests.
- No polling, PID cache, or lock file.

### A-002 — Runtime gating and shared recovery

Goal: prevent all secondary side effects.

Planned files:

- `Sources/App/MacToolsApp.swift` — early election, minimal delegate, remove polling.
- `Sources/App/MacToolsAppRuntime.swift` — new; owner runtime composition.
- `Tests/App/MacToolsAppDelegateTests.swift` — primary/secondary, readiness/retry, reopen transitions.

Exit contract:

- `PluginHost` is absent from the delegate before election.
- No bootstrap, status item, or URL router call in the secondary process.
- AppKit reopen and IPC converge on `requestSettingsRecovery()`.
- Cold launch is unchanged.

### A-003 — Multi-process evidence

Goal: test real primitives, not only fakes.

Planned files:

- `Tests/App/AppInstanceCoordinatorProcessTests.swift` — subprocess orchestration.
- `Tests/Support/AppInstanceProbe/` — minimal test executable, with no UI or user data.
- `project.yml` and test configuration generator if needed — Debug-only helper target.
- `docs/features/app-reopen-recovery.md` — results and append-only journal.
- `README.md` — document the user recovery path.
- `changes/unreleased/app-reopen-recovery.md` — final user-facing wording.

Automated scenarios:

- two, then ten concurrent processes: exactly one owner;
- one command per secondary; ACK and exit 0;
- command received before handler readiness;
- owner crash then promotion;
- unresponsive owner: timeout, no second runtime;
- different bundle IDs: independence;
- invalid message/version: rejection.

All artifacts use a temporary test namespace. They never access real preferences or directories.

### A-004 — Certification

Goal: decide whether the PR may leave Draft. Do not make it Ready automatically.

Gates:

- focused coordinator, delegate, and window-router tests;
- green multi-process test with no flaky retries;
- green `MacToolsTests` suite;
- Debug `make build`;
- Release build;
- `git diff --check`;
- separate Spec review;
- separate standards review;
- real Finder, Spotlight, Dock, and launcher QA;
- after stabilization: one active process and Settings in front;
- PR stays Draft; Ready status requires an explicit request;
- write `.Codex/rules/architecture-stability.md` only after all gates pass; baseline is the HEAD before the certification commit.

## Acceptance tests

| ID | Given | When | Then |
|---|---|---|---|
| AT-001 | No MacTools process | The app starts | One runtime; no forced window |
| AT-002 | MacTools running without visible window | Relaunch through launcher | Settings visible and active; one final runtime |
| AT-003 | MacTools running with minimized Settings | Relaunch | Same window deminiaturized and frontmost |
| AT-004 | MacTools running with another visible window | AppKit reopen | Settings shown even when `hasVisibleWindows = true` |
| AT-005 | Owner is bootstrapping | Secondary starts | Request is not lost; presentation after readiness |
| AT-006 | Ten copies start simultaneously | Coordination | One owner; nine secondaries without runtime |
| AT-007 | Owner crashes | New copy starts | Promotion; normal launch |
| AT-008 | Owner does not respond | Secondary starts | Bounded termination; no duplicate runtime |
| AT-009 | MacTools Dev and MacTools Release | Both start | Independence by bundle ID |

## Fitness functions

- Static search finds no `duplicateLaunchPollTimer`, `handledDuplicateProcessIdentifiers`, `runningApplications`, or `AppDuplicateLaunchPolicy`.
- `PluginHost(` is constructed only by approved owner-runtime composition.
- Concurrency test property: `owners == 1` for every same-namespace group.
- Secondary test property: `runtimeInitializations == 0`.
- Timeout test: total duration is below 2 seconds.
- Reopen test: exactly one presentation invocation per event.
- No product `#if DEBUG` branch in the coordinator.

## Stability envelope

- Absorbed changes: multiple DerivedData directories, Finder/Spotlight, bundle upgrade, primary crash, future idempotent local command.
- Thresholds: one runtime; zero secondary bootstrap; presentation in less than 2 seconds; zero idle polling.
- Constraints: macOS 14+, Swift 6, Apple-native, `MainActor` UI, no dependency.
- Design invalidation: non-idempotent IPC command, sandbox blocking `CFMessagePort`, inter-session requirement, timeout observed during 100 QA relaunches.
- Inter-version compatibility: stop/restart is required if an older version publishes no port; coexistence is not promised.

## Rollback

- Isolated revert of `AppInstanceCoordinator` and `MacToolsAppRuntime`.
- Restore only the AppKit reopen callback; do not restore polling.
- No user-preference format or user data migration.
- No persistent lock or socket to clean up.
- Keep the PR Draft if a gate fails.

## Out of scope

- Change the plugin behavior that hides the menu bar.
- Add a global recovery shortcut.
- Change Finder, Spotlight, or the launcher.
- Add automatic preference restoration.
- Add a third-party dependency or XPC service.
- Merge or make the PR Ready.

## Closed decisions

- IPC: `CFMessagePort`, not polling or notification without ACK.
- Uniqueness: atomic named-port registration, not PID.
- Failure: fail closed; never run a second runtime.
- Presentation: central handler to `AppWindowRouter.showSettings()`.
- Scope: same Debug/Release code, isolated by bundle ID.
- Delivery: Draft until explicit request and certification.
