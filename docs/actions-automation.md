# Actions, Automation, Run Links, and Action Grid

MacTools exposes one host-owned action platform to every invocation surface. Plugins publish stable action definitions and catalog entries; the host owns lookup, migration, availability, shortcut registration, confirmation, and execution.

## Ownership

- `ActionRegistry` owns revisioned in-memory definition/catalog indexes and live availability invalidation.
- `ActionExecutor` is the only execution gate. It validates parameters and execution mode, applies confirmation policy, revalidates the provider and availability, and enforces cancellation and timeouts.
- `ShortcutAssignmentService` owns ordinary global-action bindings, conflicts, migration, persistence, and Carbon registration state. Plugin-specific and central editors are projections of the same records.
- Automation owns workflow definitions, rules, conditions, and bounded privacy-conscious history. Steps store versioned `ActionReference` values and execute serially through `ActionExecutor`.
- `AppURLRouter` owns one strict, ordered, bounded route queue. Run Links resolve to `ActionReference` values before execution.
- Action Grid owns only its ordered, versioned list of up to nine references. Catalog discovery, owner navigation, migration, availability, execution, shortcut assignment, and Run Link generation remain host-owned.

Unavailable references are retained by shortcut assignments, workflows, presets, and Action Grid. A provider returning with a compatible migration can restore them without recreating user configuration.

## Automation boundaries

Workflows can be created, renamed, duplicated, enabled or disabled, reordered, run, tested, stopped, and deleted. Automatic rules are managed separately; deleting a workflow explicitly removes its attached rules so enabled orphan triggers cannot remain hidden. Manual Run and Test ignore rule-specific conditions. Enabled workflows publish stable `automation/workflow.<uuid>` actions, so Unified Search, global shortcuts, Run Links, and Action Grid need no workflow-specific dispatch path.

Automatic rules use one trigger and zero or more conditions:

```text
When: schedule, calendar, application, power, display, or network event
If:   frontmost app, power/battery, connected display, time range, or network state
Run:  reusable workflow
```

Trigger delivery is debounced, serialized per rule, and bounded. Skipped rules record a concise reason. Workflow recursion and execution depth are bounded; history recovers unfinished runs as interrupted after a restart. Advanced branches, loops, variables, folders, and application-specific Action Grid profiles are intentionally outside this release.

## Automated verification

Use focused tests while developing, then the full suite for cross-module changes:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet
```

The test suite covers registry revisions and migration; parameter validation; executor safety, confirmation, cancellation, and timeout behavior; shortcut persistence/conflicts/registration/reentrancy and unavailable-provider visibility; Run Link parsing, queue bounds, presets, feedback, and privacy; workflow editing, ordering, rule cleanup, recovery, cancellation, execution, recursion, startup sequencing, and history; all trigger/condition families with injected providers; and Action Grid storage, migration, geometry, keyboard mapping, distinct accessible controls, repeat presentation, unavailable actions, and shared execution.
