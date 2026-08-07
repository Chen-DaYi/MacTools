# Saved Scripts

## Product goal

Saved Scripts is useful as a complete standalone tool. Automation, Action Grid, gestures, shortcuts, and Run Links are optional ways to reuse a script, not prerequisites for creating or running one.

## Standalone experience

- The plugin settings page is a searchable script library with one-click Run or Stop, edit, duplicate, delete, and recent captured output.
- The Feature Panel exposes up to eight saved scripts plus a direct **Manage Scripts…** action. It shows a spinner while a script runs and retains the completion, failure, or cancellation status briefly so fast scripts still provide visible feedback.
- The editor supports AppleScript, zsh, Bash, and POSIX shell, an optional working directory, a bounded slider plus numeric timeout, and **Save & Run**.
- Last-run output is session-only. It is not written to preferences or included in backup.

## Unified action model

Every saved script publishes one canonical action with a stable identifier derived from the script UUID. The same action can be selected by Actions & Shortcuts, Trackpad Gestures, Action Grid, and Automation without copying script source into those features. Deleting a script leaves consumers with an unavailable action reference that can recover if a backup restores the same script identifier.

Run Links are disabled per script by default and always require confirmation when enabled. Normal action surfaces also require confirmation by default; an individual script may turn that confirmation off to run immediately from Action Grid, Trackpad Gestures, shortcuts, and workflows. Direct Run from Saved Scripts or its Feature Panel is already an explicit user action and does not add a second prompt.

## Execution and data safety

- Each script type uses a fixed absolute interpreter path. Script source is written to a mode-0600 temporary file and passed as an argument; it is never interpolated into a shell command.
- The runner supplies a minimal environment, validates the working directory, supports cancellation, enforces a 1–300 second timeout, and caps captured output at 64 KB.
- Saved Scripts never adds `sudo` or requests administrator privileges. AppleScript may still cause macOS to request Automation access for the application targeted by the script.
- Source is excluded from portable preferences backup unless the user opts in for that script. Working directories are always removed from the portable copy because machine-specific paths are rarely portable and may disclose local information.
