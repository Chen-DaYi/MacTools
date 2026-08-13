# Feature — Input Remapping

Last verified: 2026-08-13

Status: in-progress
Source of truth: yes

## Summary

- Separate plugin for remapping keyboard, mouse, and precise trackpad gestures.
- Scope: keyboard keys, mouse click/double-click/long-press, scroll wheel, and the precise gestures already recognized by Trackpad Gestures.
- Out of scope: shell commands, macros, profiles, per-app or per-device conditions.

## User flow

- User grants Accessibility and Input Monitoring.
- User adds, enables, edits, or removes a persisted rule.
- To select a trigger, the user starts recording and presses a key, a mouse button, or scrolls; the recorded event and its matching key-up or mouse-up are consumed without executing a rule.
- Recording first shows a brief preparation state so the click that opened the recorder cannot become the trigger; it then shows an explicit listening state.
- A matching click, key, or scroll executes the action. Mouse double-click and long-press keep the original click available to avoid unsafe event replay.
- When the action is a shortcut, the user can record the output combination directly; the recorded key-down and key-up are consumed.
- Each rule presents its Input, Output, and Context in three stable columns. Context is currently global; per-app and per-device conditions remain out of scope.
- A missing rule, failed action, or event carrying the Input Remapping marker passes through unchanged.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Physical mouse buttons: 0 through 32 | This document | `InputRemappingRulePolicy` | Rule model, matcher, recorder |
| Capture accepts keyboard, mouse buttons, and scroll and consumes the recorded event | This document | `InputRemappingCapturedInput` | Settings editor, CGEvent tap |
| Recording arms after its opening click and distinguishes preparation from active listening | This document | `InputRemappingButtonCaptureCoordinator` | Input and shortcut recorders |
| Shortcut output can be recorded directly and consumes its key pair | This document | `InputRemappingButtonCaptureCoordinator` | Shortcut action editor, CGEvent tap |
| Exact modifier set required | This document | `InputRemappingRule.matches` | Event processor |
| A consumed down consumes its matching up | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Events carrying the Input Remapping synthetic marker always pass through | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Failed or inapplicable actions fail open | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| A keyboard trigger with no modifier is saved disabled and requires explicit confirmation before it can be enabled | This document | `InputRemappingRule` | Rule editor, event processor |
| A precise trackpad gesture belongs to either Trackpad Gestures or Input Remapping, never both | This document | Shared trackpad gesture broker | Plugin host, both plugins |
| Rule context is global only | This document | Rule editor layout | Context column |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-13 | Mission Control and Spaces use standard Control shortcuts | Match configurable macOS shortcuts without private APIs | Mission Control and space navigation |
| 2026-08-13 | Media and volume use macOS auxiliary `systemDefined` events | Function keys are not media keys on every keyboard or configuration | Play/pause and volume actions |
| 2026-08-13 | Failed or inapplicable rule keeps the original event | Preserve native mouse behavior | Fail-open behavior |
| 2026-08-13 | Permission checks are injected behind plugin seams | Cards and activation use the same real OS state and remain testable | Accessibility and Input Monitoring |
| 2026-08-13 | Synthetic-event protection is limited to the private Input Remapping marker | Public CoreGraphics source fields describe state tables or process metadata, not a reliable physical-versus-generated category | Unmarked third-party generated events can match a rule |
| 2026-08-13 | Modifier-free keyboard triggers are allowed after a warning | User requires full flexibility while being informed of global typing risk | Rule remains disabled until confirmation |
| 2026-08-13 | Trackpad gesture ownership is exclusive | A single Multitouch listener must arbitrate gestures | New Input Remapping claim removes the Trackpad Gestures mapping |

## Known limitation

- Input Remapping-generated events carry a private marker and cannot loop back into remapping.
- macOS exposes no reliable public category for every generated event.
- A third-party generated, unmarked mouse event in the 3...32 range can match and execute a rule.

## Plan

- [x] P001 — Define scope and acceptance contract.
- [x] P002 — Add persisted rule model, CGEvent tap, and action execution.
- [x] P003 — Add localized rule editor and real permission state/actions.
- [x] P004 — Cover matching, down/up lifecycle, fail-open behavior, persistence, and plugin state.
- [x] P005 — Address first review findings.
- [x] P006 — Address second review findings and narrow unsupported synthetic-event claims.
- [x] P007 — Replace numeric trigger selection with a direct mouse-button recorder.
- [x] P008 — Generalize triggers to keyboard, mouse click/double-click/long-press, scroll, and precise trackpad gestures.
- [x] P009 — Add shared trackpad gesture arbitration and migration from Trackpad Gestures.
- [x] P010 — Redesign the rule editor around Input, Output, and Context columns.
- [x] P011 — Present each mapping as a card following When I press → Run → Where.
- [x] P012 — Match the approved card positioning and native control hierarchy.
- [x] P013 — Keep the mapping workspace within the host's standard readable-width guide.

## Acceptance / DoD

- [x] Rules can be enabled, edited, removed, and persisted.
- [x] Trigger requires button 3 through 32 and the exact optional modifier set.
- [x] Actions: shortcut, back/forward/middle, Mission Control, left/right space, media, and volume up/down.
- [x] Media and volume actions emit auxiliary system events, not ordinary F8/F11/F12 keystrokes.
- [x] Accessibility and Input Monitoring cards report real state and expose working actions.
- [x] Successful remapping consumes both down and matching up.
- [x] Failed actions, unmatched events, unpaired up events, and Input Remapping-marked events pass through.
- [x] Every plugin deactivation stops the event tap.
- [x] Returning to MacTools after System Settings revalidates both permissions and reapplies tap state.
- [x] User-facing plugin copy resolves through `PluginLocalization` and `Localizable.xcstrings`.
- [x] Settings use a validated `.form`, theme tokens, labels, and explicit control sizing.
- [x] Trigger selection uses a cancellable direct button recorder instead of a numeric stepper.
- [x] Adjacent targeted tests cover the behavioral seams.
- [x] Keyboard keys, mouse buttons, and scroll can be recorded as a trigger from the rule editor.
- [x] Modifier-free keyboard triggers show a warning and require confirmation before activation.
- [x] A trackpad gesture cannot remain active in both plugins.
- [x] The rule editor separates Input, Output, and global Context into three columns.
- [x] Unmodified keyboard triggers persist disabled until their explicit confirmation.
- [x] Mouse double-click actions preserve the native click pair.
- [x] Shortcut recording exposes preparation and active-listening states.
- [x] Each mapping card exposes its trigger, action, and global context in the requested flow layout.

## Implementation journal

- 2026-08-13 — Contract, MVP scope, plan, feature index, and changelog fragment added.
- 2026-08-13 — Initial plugin added with JSON rule persistence, CGEvent tap, permission cards, and settings editor.
- 2026-08-13 — Review P1 fixed: tap now observes both `otherMouseDown` and `otherMouseUp`; `InputRemappingEventProcessor` consumes an up only after the matching down executed successfully, while preserving synthetic-event protection and fail-open behavior.
- 2026-08-13 — Review P1 fixed: permission cards now use injected Accessibility and IOHID state providers; actions prompt for Accessibility or open the Input Monitoring system pane; unknown permission IDs are never reported as granted.
- 2026-08-13 — Review P2 fixed: play/pause and volume actions now post `NX_KEYTYPE_*` auxiliary system events; rule bounds are centralized; storage decode/encode failures are logged; all user-facing plugin strings use plugin localization; settings use the host form/theme conventions.
- 2026-08-13 — Tests expanded for matching, bounds, down/up lifecycle, fail-open and synthetic events, persistence, permissions, activation, deactivation, and settings validation.
- 2026-08-13 — Checks passed: Swift parse for plugin sources and tests, string catalog JSON parse, and scoped `git diff --check`. Targeted XCTest could not run because the generated local Xcode project does not yet contain the `InputRemappingPlugin` scheme; generating project files is outside this agent's assigned files.
- 2026-08-13 — Review 2 fixed: auxiliary event data encodes down/up state once; persisted and copied button values normalize to 3...32; matching uses typed `CGEventFlags`; application activation revalidates both permissions with observer cleanup on deactivation; the Add action moved to the host section header and editor rows use edge-to-edge list chrome.
- 2026-08-13 — Synthetic-event contract narrowed to Input Remapping-marked events after checking the public CoreGraphics event-source APIs; unmarked third-party generated events remain a documented risk.
- 2026-08-13 — Review 2 checks passed: Swift parse, source module emission, test typecheck, both JSON parses, tracked `git diff --check`, and whitespace checks for untracked feature files. No project lint command or user pre-commit hook is configured. Targeted XCTest remains unavailable because the generated local Xcode project has no `InputRemappingPlugin` scheme.
- 2026-08-13 — UX refined: each rule now records the physical extra mouse button directly. The recorder has an explicit cancel action and lets the captured click pass through, avoiding accidental remapping during selection.
- 2026-08-13 — Verification: generated the project, built `InputRemappingPlugin`, and passed `MacToolsTests/InputRemappingModelsTests`. Existing DiskClean Swift-concurrency warnings remain outside this feature.
- 2026-08-13 — User expanded the contract to keyboard, mouse click/double-click/long-press, scroll, and the precise Trackpad Gestures catalog. Modifier-free keys require confirmation; trackpad ownership is exclusive and must be brokered through the host.
- 2026-08-13 — Implemented universal capture and persisted keyboard, mouse, scroll, and trackpad triggers. Double-click executes on the second down; long-press executes on release; both retain the source click to avoid buffering and replaying native input.
- 2026-08-13 — Added a PluginKit trackpad gesture catalog and host broker. Trackpad Gestures remains the sole Multitouch listener; a new Input Remapping claim removes the conflicting local mapping and receives subsequent recognition.
- 2026-08-13 — Recording now consumes the captured event and matching key-up or mouse-up; a successful keyboard remap also consumes both key-down and matching key-up. macOS no longer receives the source input after capture or remapping.
- 2026-08-13 — Added a dedicated shortcut-output recorder. It captures the next keyboard combination and consumes its full key pair.
- 2026-08-13 — Redesigned the rule editor into stable Input, Output, and Context columns. The input column reveals only source-specific controls; Output keeps action and shortcut recording together; Context contains scope, enablement, safety guidance, and deletion. Global scope is explicit while conditional contexts remain out of scope.
- 2026-08-13 — Fixed accidental input capture: the recorder waits briefly after the Record button action before arming. The UI communicates “Preparing recording” then “Listening for an input”; regression coverage proves the opening mouse click is ignored.
- 2026-08-13 — Replaced repeated rule cards with a master-detail workspace: a compact selectable `Input → Output` rule list on the left and one three-column selected-rule editor on the right. Selection safely falls back to the first rule after additions or deletions.
- 2026-08-13 — Reverted the master-detail workspace at user request. Rules again render directly in the settings list; the three-column Input, Output, and Context editor remains for each rule.
- 2026-08-13 — Review fixes: unmodified keyboard triggers now centrally persist disabled until confirmation; double-click actions preserve their native click pair; shortcut recording renders preparation and listening states; universal matcher, interaction, and trackpad-claim paths have targeted coverage; universal copy and human-readable localized trackpad gesture titles replace stale button-only and raw identifiers.
- 2026-08-13 — Checks passed: generated project, `InputRemappingPlugin`, `TrackpadGesturesPlugin`, and `MacTools` Debug builds; targeted Input Remapping XCTest passed through the MacTools scheme; localization JSON parse and `git diff --check` passed. The plugin scheme has no test action.
- 2026-08-13 — Kept the mapping workspace within the host's readable-width guide; responsive column minimums preserve all three controls in a narrow detail pane without overflowing the sidebar.
- 2026-08-13 — Reworked the mappings list into individual cards matching the approved When I press → Run → Where flow. The page subtitle is “Create shortcuts from keyboard/trackpad/mouse”; enablement and destructive actions moved to the card header/footer.
- 2026-08-13 — Removed the enclosing Form section card. The settings page now uses its task-oriented workspace shell, leaving only the individual mapping cards visible.
- 2026-08-13 — Aligned mapping cards with the approved reference: bordered control fields, one shortcut value field rather than duplicated output controls, and the exact conditional Run presentation for shortcuts versus predefined actions.
- 2026-08-13 — Fixed the empty settings page: the dynamic-plugin manifest now declares the workspace layout used at runtime; its localized marketplace summary now matches the multi-device mapping scope.
- 2026-08-13 — Refined the approved card layout: full-width native menu buttons for Input, interaction, Run, and Where; recording moved into the Input menu; shortcut output uses one selectable value field plus a full-width recording action; secondary modifier controls are hidden from the primary scan path.

## Files

- `Plugins/InputRemapping/`
- `docs/features/input-remapping.md`
- `docs/features/INDEX.md`
- `changes/unreleased/input-remapping.md`

## Test / QA commands

- `swiftc -parse Plugins/InputRemapping/Sources/*.swift Plugins/InputRemapping/Tests/*.swift`
- `ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' Plugins/InputRemapping/Resources/Localizable.xcstrings`
- `xcodebuild -project MacTools.xcodeproj -scheme InputRemappingPlugin -configuration Debug -derivedDataPath build/DerivedData test -quiet`

## History

<!-- Read only for bugs, regressions, audits, or explicit requests. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
