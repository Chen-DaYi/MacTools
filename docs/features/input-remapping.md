# Feature — Input Remapping

Last verified: 2026-08-13

Status: implemented
Source of truth: yes

## Summary

- Separate plugin for remapping extra mouse buttons.
- Scope: buttons 3 through 32, with optional exact modifiers.
- Out of scope: primary clicks, trackpad, shell commands, macros, profiles, per-app or per-device conditions.

## User flow

- User grants Accessibility and Input Monitoring.
- User adds, enables, edits, or removes a persisted rule.
- A matching button-down executes the action and consumes the original down/up pair.
- A missing rule, failed action, or event carrying the Input Remapping marker passes through unchanged.

## Business rules

| Rule | Markdown | Centralized code | Consumers |
|---|---|---|---|
| Eligible buttons: 3 through 32; primary clicks and trackpad excluded | This document | `InputRemappingRulePolicy` | Rule model, matcher, settings stepper |
| Exact modifier set required | This document | `InputRemappingRule.matches` | Event processor |
| A consumed down consumes its matching up | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Events carrying the Input Remapping synthetic marker always pass through | This document | `InputRemappingEventProcessor` | CGEvent tap callback |
| Failed or inapplicable actions fail open | This document | `InputRemappingEventProcessor` | CGEvent tap callback |

## Decisions

| Date | Decision | Reason | Impact |
|---|---|---|---|
| 2026-08-13 | Mission Control and Spaces use standard Control shortcuts | Match configurable macOS shortcuts without private APIs | Mission Control and space navigation |
| 2026-08-13 | Media and volume use macOS auxiliary `systemDefined` events | Function keys are not media keys on every keyboard or configuration | Play/pause and volume actions |
| 2026-08-13 | Failed or inapplicable rule keeps the original event | Preserve native mouse behavior | Fail-open behavior |
| 2026-08-13 | Permission checks are injected behind plugin seams | Cards and activation use the same real OS state and remain testable | Accessibility and Input Monitoring |
| 2026-08-13 | Synthetic-event protection is limited to the private Input Remapping marker | Public CoreGraphics source fields describe state tables or process metadata, not a reliable physical-versus-generated category | Unmarked third-party generated events can match a rule |

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
- [x] Adjacent targeted tests cover the behavioral seams.

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
