# Canonical action provider coverage

`PluginActionProviding` is the default integration point for a reusable plugin operation. A canonical action can appear in Actions & Shortcuts, Unified Search, Trackpad Gestures, Action Grid, and Automation. It may also support Run Links when its parameters and safety model are suitable for external invocation.

This inventory records the current migration boundary. It prevents a plugin from accidentally growing a second, surface-specific execution path and makes intentional exclusions visible during review.

## Migrated providers

The following plugin source directories publish canonical actions:

- Core action surfaces: `ActionGrid`, `SavedScripts`.
- App and input control: `AppHotkey`, `AppVolume`, `AutoInput`, `WindowSwitcher`.
- Display and workspace control: `Appearance`, `DisplayBrightness`, `DisplayResolution`, `DisplaySleep`, `DisplayTrueColor`, `HideNotch`, `NightShift`, `Sidecar`, `StageManager`.
- Menu bar and Dock control: `AutoHideDock`, `AutoHideMenuBar`, `MenuBarHidden`.
- System and device control: `BatteryChargeLimit`, `FanControl`, `KeepAwake`, `LockScreen`, `MicrophoneMute`, `SystemMute`.
- Productivity and maintenance: `ActivityBar`, `ClipboardClear`, `EjectDisk`, `EmptyTrash`, `FixDamagedApp`, `Launchpad`, `PhysicalCleanMode`, `QuitApps`, `Translator`.

Parameterized actions publish concrete catalog entries rather than asking each action surface to construct parameters. For example, Sidecar publishes per-device entries, Display Resolution publishes current display modes, App Volume publishes current audio apps, Battery Charge Limit publishes useful limit presets, and Fan Control publishes saved presets. Availability is resolved again at execution time so stale hardware, processes, or configuration fail safely.

Operations that eject storage, empty Trash, clear the clipboard, change hardware management, or enter a physical clean session preserve confirmation or foreground-only requirements. Machine-local parameters are marked local-only, and actions that require an interactive chooser or key lifecycle do not expose Run Links.

## Intentionally specialized or non-operational

These plugins should not publish a canonical action merely to appear in action pickers:

- `Calendar`, `DeviceBattery`, `IPOverview`, and `SystemStatus` primarily present information.
- `RightClick` extends Finder context menus rather than representing one repeatable operation.
- `TrackpadGestures` is an input surface that consumes canonical actions; it is not itself an action provider.
- `ZshConfig` manages configuration whose edits require contextual review.

Specialized shortcuts may remain when their input lifecycle cannot be represented by one invocation. Window Switcher keeps its press, release, and repeat shortcut behavior in addition to a canonical action that opens the interactive chooser. Physical Clean Mode keeps its emergency exit binding separate from the canonical enter action.

## Design-first backlog

The following plugins contain useful operations but need a narrower action contract before migration:

- `DiskClean` and `XcodeClean`: publish saved, reviewed cleanup plans rather than a broad one-click deletion action.
- `Homebrew`: publish explicit package/service operations with target identity, progress, and confirmation rather than mirroring every UI button.
- `LaunchControl`: publish saved launch-agent operations only after privilege, ownership, and stale-target behavior are explicit.
- `MouseEnhancer`: keep device and scrolling configuration in settings unless a clear repeatable operation emerges.

When one of these contracts is designed, prefer stable readable action IDs, concrete catalog entries, live availability checks, bounded execution, and the narrowest external invocation policy that preserves the plugin's existing safety boundary.
