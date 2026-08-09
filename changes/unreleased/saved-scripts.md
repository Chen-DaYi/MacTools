---
release: plugin
type: added
---

Added Saved Scripts for securely keeping and directly running AppleScript, zsh, Bash, and POSIX shell scripts with a direct numeric timeout, cancellation, captured output, and visible running and recent completion status in the Feature Panel. Timeouts, deletion, plugin shutdown, user cancellation, and importing a replacement definition terminate the affected script’s complete process group; bounded output cannot keep a finished run open, and only abandoned MacTools-owned temporary source files are removed on the next launch. Each script can also appear as a stable action in shortcuts, trackpad gestures, Action Grid, workflows, and explicitly enabled Run Links, with a clear per-script option to ask before other MacTools features run it, while source backup remains opt-in and importing the category replaces the local script library. Corrupt libraries remain protected from ordinary edits until a valid backup replaces them. Scripts remain available on every action surface when local confirmation is disabled but confirmed Run Links are enabled.
