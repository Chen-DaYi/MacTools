# Actions and Automation E2E Evidence

This opt-in local harness prepares deterministic, non-destructive examples for the Actions & Shortcuts, Automation, Run Link, and Action Grid features from issues #247, #249, #250, and #251. It uses the stable signed Debug app at `~/Applications/MacTools Dev.app` and never runs from Derived Data.

The harness is not part of the normal build, test, CI, release, or production launch flow.

## Safety model

`make e2e-prepare` first stops the stable Debug app gracefully and exports both its main preferences domain and Finder extension preferences domain into a timestamped directory under `build/E2EArtifacts/`. It then installs a temporary fixture and relaunches exactly one app instance.

The fixture preserves unrelated action shortcut assignments and creates:

- four shortcuts: Control-Command-3 for Open Settings, Control-Command-4 for Action Grid, Control-Command-5 for Dashboard, and Control-Command-6 for the safe workflow;
- five workflows covering success, background execution, continue-on-error, stop-on-error, and cancellation during delay;
- three application-activation rules covering a successful Calculator run, a skipped Calculator condition, and a successful TextEdit run;
- nine Action Grid entries spanning host commands, plugin actions, workflows, and one deliberately unavailable action;
- English and the light appearance for deterministic starting evidence.

The background workflow reads the current system mute value and writes the same value back. Fixture workflows never contain Display Sleep, Lock Screen, Empty Trash, or another side-effecting confirmation action: workflow invocations are not external Run Links and therefore do not apply `confirmAlways`. Confirmation is tested separately at the Run Link boundary and must always be cancelled. The remaining fixture actions only navigate within MacTools or use a deliberately missing provider.

`make e2e-restore E2E_SESSION=...` restores both preference domains exactly from the original session backup. Backups and evidence remain in the session after restoration.

## Before granting permissions

Run the permission-independent checks:

```bash
make e2e-self-test
make e2e-preflight
```

Preflight verifies the stable app path, deep signature, Apple Development authority, Team ID, installed Debug plugins, process count, recorder dependencies, and whether the process hosting the harness can post synthetic shortcuts. It also rejects a leftover Derived Data test host, because a second app with the development bundle identity can steal Run Links from the stable app. It reports permission state without opening System Settings, resetting TCC, requesting access, or accepting a prompt.

## Prepare or upgrade a session

Create a new session once:

```bash
make e2e-prepare
```

Save the absolute session directory printed on the last line:

```bash
E2E_SESSION=/absolute/path/from/prepare
make e2e-audit E2E_SESSION="$E2E_SESSION"
```

`fixture.audit.json` must report `"valid": true` before UI automation begins.

If the session was prepared with an older fixture, upgrade it in place:

```bash
make e2e-upgrade E2E_SESSION="$E2E_SESSION"
```

Upgrade preserves the original preference backups and existing screenshots, installs the current fixture, clears fixture history, and resets every required checkpoint to `pending` so stale evidence cannot pass the current scenario manifest.

Return to a prepared session without touching its backup or fixture:

```bash
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

Reset only the fixture between mutation-heavy scenario packs:

```bash
make e2e-reseed E2E_SESSION="$E2E_SESSION"
```

Reseed clears fixture history and restores the deterministic fixture but does not change checkpoint results or replace the original backups.

## Scenario manifest

The machine-readable source of truth is `scripts/e2e/scenarios.json`. List all packs or inspect one pack with:

```bash
make e2e-scenarios
scripts/e2e/mactools-e2e.sh scenarios workflow-resilience
```

Every required checkpoint in the manifest must pass. The physical-trackpad pack is explicitly optional because neither Accessibility nor Computer Use can synthesize the private raw multitouch stream.

Computer Use must query fresh accessibility state after every transition. Do not retain numeric element indexes after the UI changes. Record a checkpoint immediately after its assertion succeeds:

```bash
scripts/e2e/mactools-e2e.sh checkpoint "$E2E_SESSION" marketplace-visible pass
```

## Pre-permission scenario packs

### Baseline cross-surface path

1. Open `mactools-dev://app/settings/plugins/marketplace`; assert the current catalog contains 44 plugins and installed local plugins are verified.
2. Open Actions & Shortcuts; assert its search field and all four fixture assignments are visible.
3. Open Automation; assert all five workflows, their expected step counts, and all three rules are visible.
4. Run `E2E Safe Workflow`; assert its three steps and overall run succeed and the app remains responsive.
5. Run the same workflow through its Run Link; assert another successful run with persisted source `publishedAction.runLink`.
6. Open `mactools-dev://app/actions/action-grid/show`; assert nine accessible grid controls, then dismiss with Escape.
7. Open `mactools-dev://app/actions/launchpad/toggleLaunchpad`; assert Launchpad appears, then dismiss it.
8. Launch Calculator with `open -a Calculator`; assert `E2E Calculator Activation` succeeds, `E2E Calculator Condition Skip` records a condition skip, and fixture audit still reports `systemMuteStatePreserved: true`.
9. Close Settings, send Control-Command-3, and assert General Settings appears. Send Control-Command-4 and assert one Action Grid overlay appears.
10. Quit and relaunch the stable app; assert the four shortcuts, five workflows, three rules, nine grid entries, and recent history persist.

The shortcut driver refuses to request permission or post an event when access is absent. Its mappings can always be checked safely:

```bash
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" open-settings --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" action-grid --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" dashboard --dry-run
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" safe-workflow --dry-run
```

### Shortcut lifecycle

Reseed first. In Actions & Shortcuts, try assigning Control-Command-5 to Open Settings. Assert the existing Dashboard conflict is named, approve replacement, verify Dashboard becomes unassigned, clear the replacement, and verify both rows update. Assign or clear the same action from Command-K search and assert the central shortcuts page updates immediately. Reseed afterward.

### Workflow resilience

Reseed first, then run each fixture workflow separately:

- `E2E Continue After Missing Action`: assert succeeded, unavailable, succeeded step states and a failed overall result.
- `E2E Stop On Missing Action`: assert the missing step is unavailable and its following step is skipped.
- `E2E Cancellable Delay`: stop it during its ten-second delay and assert cancelled status.
After every run, assert the deliberately unavailable step remains editable and visible rather than being silently removed. Reseed afterward.

### Automation conditions

Reseed and verify all three enabled rules. Launch Calculator once and assert one successful run and one skipped condition result, with no duplicate success. Launch TextEdit with `open -a TextEdit` and assert its rule succeeds once. Audit the fixture again to prove the mute state was preserved. Reseed afterward.

### Run Link security and lifecycle

Use the safe workflow for direct-link and copy checks. Expand Run Link, copy both the URL and terminal command, and assert the temporary copied-state feedback appears. For the parameterized preset, read `systemMuteValue` from `fixture.audit.json`, find the System Mute catalog action that sets that same value, create and execute its preset, and assert the mute value remains unchanged. Delete the preset and verify its old link no longer runs. Never choose the opposite mute action for this test.

Search Actions & Shortcuts for Display Sleep, invoke its direct Run Link, and cancel the external confirmation. Never press the Sleep button. Exercise rejection with an unknown action and a percent-encoded path separator, for example:

```bash
open -a "$HOME/Applications/MacTools Dev.app" 'mactools-dev://app/actions/e2e-missing-provider/not-installed'
open -a "$HOME/Applications/MacTools Dev.app" 'mactools-dev://app/actions/mactools%2Fbad/app.open-settings'
```

Assert visible rejection or matching diagnostics and no side effect. Finally quit the app, submit a navigation link followed immediately by two distinct safe action links, and assert the cold-launch queue runs each action once and in submission order. Reseed afterward.

### Action Grid interactions

Reseed and verify the 3-by-3 nine-entry layout. In settings, add or replace an entry, reorder it, clear it, and assert the overlay mirrors each change. Invoke the safe workflow entry and verify its history source. Invoke the unavailable entry and assert the grid stays open with an accessible error. Exercise arrow navigation, Return, numeric selection, Escape, outside-click dismissal, and rapid repeated invocation; assert focus is correct and at most one overlay exists. Reseed afterward.

### Localization and host commands

Start from the English fixture and capture the main feature pages. Switch to Simplified Chinese and assert host and plugin copy localize without truncation. Switch to Arabic and assert right-to-left layout and readable mixed identifiers; this is a layout assertion, not a translation-completeness waiver.

Use Command-K to change appearance and restore it, then hide and restore one plugin surface. Assert the settings controls and visible panels stay synchronized. Reseed to restore English/light and plugin visibility.

### Stability and migration

Open Dashboard repeatedly with Control-Command-5 while Bluetooth state refreshes; assert the UI remains responsive and exactly one stable app process exists. Repeat mixed Dashboard, Feature Panel, Settings, and Action Grid presentation enough times to expose duplicate-window or stale-state failures.

Run the isolated plugin-catalog and migration tests and only mark `plugin-migration-isolated-tests` after they pass. These prove that legacy built-in records do not hide, uninstall, or corrupt the dynamically packaged replacements.

### Trackpad automated coverage

Open Trackpad Gestures settings and assert all gesture editors, enablement state, validation, and permission guidance are accessible. Run the Trackpad Gestures XCTest classes, which inject gesture events and cover recognition, persistence, assignment, validation, and action dispatch without physical input. Do not claim raw hardware verification from these tests.

Run both code-verification groups immediately after prepare or upgrade, before collecting UI evidence, and record their two checkpoints automatically with:

```bash
make e2e-verify-code E2E_SESSION="$E2E_SESSION"
```

The migration and trackpad logs are retained in the session. The command temporarily stops the stable app so its XCTest host cannot compete for preferences or URLs. XCTest can leave its Derived Data host running and register that bundle as a `mactools-dev://` handler, so cleanup stops and unregisters only that exact test host, force-registers the stable installed app, and reopens the stable Marketplace. A command-only preview is available with `scripts/e2e/mactools-e2e.sh verify-code "$E2E_SESSION" --dry-run`.

## Post-permission stable rebuild

After granting the requested macOS permissions to `~/Applications/MacTools Dev.app`, rebuild and replace that exact stable bundle without changing its path, bundle identifier, Team ID, or designated requirement:

```bash
make e2e-rebuild E2E_SESSION="$E2E_SESSION"
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

`e2e-rebuild` builds the host and local plugins, verifies the staged identity, keeps the previous app inside the session as a recoverable backup, replaces the stable bundle, compares before/after designated requirements, and relaunches it. It does not reseed or restore preferences. Preview it without mutation with:

```bash
scripts/e2e/mactools-e2e.sh rebuild "$E2E_SESSION" --dry-run
```

Repeat shortcut invocation, relaunch persistence, and the relevant permission-backed behavior. Assert the permissions remain granted and no new macOS prompt appears before marking `rebuild-permission-persistence`.

## Physical trackpad check

The optional final pack follows `Plugins/TrackpadGestures/MANUAL_TESTING.md` on a physical trackpad. Capture the configured gesture firing once, an intentionally non-matching gesture doing nothing, and the permission-denied guidance if applicable. This check supplements the injected XCTest coverage; it is not required for the automated report to pass.

## Per-pack screencasts

Dry-run without requesting Screen Recording access:

```bash
scripts/e2e/mactools-e2e.sh record-pack "$E2E_SESSION" workflow-resilience 90 --dry-run
```

After Screen Recording is granted to the recorder's host process, record bounded, reviewable clips:

```bash
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=baseline E2E_DURATION=90
make e2e-record-pack E2E_SESSION="$E2E_SESSION" E2E_PACK=workflow-resilience E2E_DURATION=90
```

Each pack writes `screencast.<pack>.mov`, `screencast.<pack>.mp4`, and `screencast.<pack>.sha256`, then automatically marks `screencast-captured` as passed. The capture is cropped to the largest visible standard MacTools window and includes the pointer and click indicators, but no microphone or system audio. It fails closed when that window cannot be resolved; it never falls back to the full display, so unrelated background windows cannot enter the recording. Keep the MacTools window stationary while recording. Recorder permission is separate from MacTools permission and may be attributed to Codex or the terminal host.

## Evidence and restoration

Build the machine-readable report and diagnostic bundle:

```bash
make e2e-collect E2E_SESSION="$E2E_SESSION"
```

The bundle contains `report.json`, the scenario-manifest version and per-pack coverage, fixture state, signature and designated-requirement evidence, recent app logs, process evidence, checkpoint results, and hashes for every screenshot, code-verification log, and screencast. `report.json` passes only when preflight and fixture validation pass and the checkpoint set exactly matches the current required manifest with every checkpoint marked `pass`. The optional physical-trackpad checkpoint is reported separately.

Always restore the user's preferences after the run, including after a failed or interrupted test:

```bash
make e2e-restore E2E_SESSION="$E2E_SESSION"
```

The harness never deletes the session directory or its original preference backups.
