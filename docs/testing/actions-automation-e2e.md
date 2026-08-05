# Actions and Automation E2E Evidence

This opt-in local harness prepares a deterministic, non-destructive scenario for the Actions & Shortcuts, Automation, Run Link, and Action Grid features. It uses the stable signed Debug app at `~/Applications/MacTools Dev.app` and never runs from Derived Data.

The harness is not part of the normal build, test, CI, release, or production launch flow.

## Safety model

`make e2e-prepare` first stops the stable Debug app gracefully and exports both its main preferences domain and Finder extension preferences domain into a timestamped directory under `build/E2EArtifacts/`. It then installs a temporary fixture and relaunches exactly one app instance.

The fixture:

- preserves unrelated action shortcut assignments;
- assigns Control-Command-3 to Open Settings;
- assigns Control-Command-4 to Show Action Grid;
- creates `E2E Safe Workflow`, whose three steps only move between MacTools windows;
- creates `E2E Background Workflow`, whose single background-safe step reads the current system mute state and writes that same value back;
- creates an enabled Calculator-activation rule for the background workflow;
- configures Action Grid with Settings and Launchpad entries;
- selects English and the light appearance for deterministic evidence.

`make e2e-restore E2E_SESSION=...` restores both preferences domains exactly from the session backup. Backups and evidence are retained after restoration.

## Before granting permissions

Run the permission-independent checks:

```bash
make e2e-self-test
make e2e-preflight
```

Preflight verifies:

- the app is installed at the stable path;
- its deep code signature is valid;
- it has an Apple Development authority and a Team ID matching `LocalConfig.xcconfig` when available;
- Debug plugin packages are installed;
- no more than one stable-path app instance is running;
- `screencapture` and `ffmpeg` are available.
- whether the process hosting the harness can post the synthetic Control-Command shortcuts.

App permission state is deliberately reported as pending. The harness does not open System Settings, reset TCC, or accept a permission prompt. Synthetic shortcut access is reported separately and never requested by preflight.

## Prepare a session

```bash
make e2e-prepare
```

The last output line is the absolute session directory. Save it for every later command:

```bash
E2E_SESSION=/absolute/path/from/prepare
make e2e-audit E2E_SESSION="$E2E_SESSION"
```

`fixture.audit.json` must report `"valid": true` before UI automation begins.

To return to an existing prepared session without touching its backup or reseeding preferences:

```bash
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

Resume revalidates the signature, plugin store, fixture, and process count, opens the stable app, and prints the remaining checkpoints plus the recording and restoration commands.

## UI scenario

Computer Use drives and checks each state from fresh accessibility data. Do not reuse numeric accessibility element indexes after the UI changes.

1. Open `mactools-dev://app/settings/plugins/marketplace`; assert Marketplace and verified local plugins are visible.
2. Select Actions & Shortcuts; assert the search field and both fixture assignments are visible.
3. Select Automation; assert both fixture workflows, the three foreground steps, the idempotent background step, and `E2E Calculator Activation` are visible.
4. Run `E2E Safe Workflow`; assert its recent history finishes successfully and the app remains responsive after Dashboard opens.
5. Open its Run Link; assert a second successful foreground run whose persisted source is `publishedAction.runLink`.
6. Open `mactools-dev://app/actions/action-grid/show`; assert the Settings and Launchpad grid controls are accessible, then dismiss with Escape.
7. Open `mactools-dev://app/actions/launchpad/toggleLaunchpad`; assert Launchpad is presented, then dismiss it.
8. Activate Calculator with `open -a Calculator`; assert the enabled application rule records a successful one-step automatic run and `systemMuteStatePreserved` remains `true` in the fixture audit. Computer Use can inspect background app controls but does not make that app frontmost, so Launch Services is the deterministic trigger for this event.
9. Close Settings, then synthesize Control-Command-3 with the stable test driver; assert a new General Settings window becomes visible.
10. Close Settings again, synthesize Control-Command-4, and assert the accessible Action Grid overlay appears with both fixture entries.
11. Quit and relaunch the stable app; assert the shortcuts, both workflows, rule, grid, and history remain.
12. After permissions are granted, rebuild and replace the stable signed app, then repeat steps 9 through 11 without accepting another prompt. This is the TCC persistence proof.

The first ten checks can run before MacTools has Accessibility, Input Monitoring, or Screen Recording permission when `eventPostingAccess` is already `true`. Otherwise the synthetic shortcut and final permission-persistence checks remain post-grant checks.

The shortcut driver refuses to request permission or send an event when access is absent. Its mapping can always be checked safely:

```bash
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" open-settings --dry-run
```

After its host has Accessibility access, the fully automated shortcut step is:

```bash
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" open-settings
scripts/e2e/mactools-e2e.sh shortcut "$E2E_SESSION" action-grid
```

## Post-permission stable rebuild

After granting the requested macOS permissions to `~/Applications/MacTools Dev.app`, rebuild and replace that exact stable bundle without changing its path, bundle identifier, Team ID, or designated requirement:

```bash
make e2e-rebuild E2E_SESSION="$E2E_SESSION"
make e2e-resume E2E_SESSION="$E2E_SESSION"
```

`e2e-rebuild` rebuilds the host and local plugins, verifies the staged signature and identity, retains the previous app inside the session as a recoverable backup, replaces the stable bundle, compares the before/after designated requirements, and relaunches the app. It does not reseed or restore preferences. A non-mutating preview is available as:

```bash
scripts/e2e/mactools-e2e.sh rebuild "$E2E_SESSION" --dry-run
```

Repeat both shortcut checks and the relaunch check. Verify the app still reports the granted permissions and no new macOS permission prompt appears, then mark `rebuild-permission-persistence` as passed.

## Screencast

Dry-run the recording command without requesting Screen Recording access:

```bash
scripts/e2e/mactools-e2e.sh record "$E2E_SESSION" 90 --dry-run
```

After Screen Recording is granted to the process hosting the recorder, start a bounded recording:

```bash
make e2e-record E2E_SESSION="$E2E_SESSION" E2E_DURATION=90
```

The recorder captures the main display, cursor, and click indicators without microphone or system audio. It writes:

- `screencast.mov` as the original capture;
- `screencast.mp4` as an H.264 copy;
- `screencast.sha256` for artifact integrity.

Recorder permission is separate from MacTools permission. Depending on how the command is launched, macOS may attribute it to Codex or the terminal host.

## Evidence and restoration

Computer Use records each result as it completes:

```bash
scripts/e2e/mactools-e2e.sh checkpoint "$E2E_SESSION" marketplace-visible pass
scripts/e2e/mactools-e2e.sh checkpoint "$E2E_SESSION" workflow-visible pass
```

Build the machine-readable report and diagnostic bundle:

```bash
make e2e-collect E2E_SESSION="$E2E_SESSION"
```

This writes `report.json`, fixture state, signature and designated-requirement evidence, recent app logs, process evidence, checkpoint results, and recording hashes. `report.json` passes only when preflight and fixture validation pass and every named UI checkpoint is marked `pass`.

Always restore the user's preferences after the run, including after a failed or interrupted test:

```bash
make e2e-restore E2E_SESSION="$E2E_SESSION"
```

The harness never deletes the session directory or its preference backups.
