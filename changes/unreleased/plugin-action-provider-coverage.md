---
release: plugin
type: added
area: Productivity
---

Expanded reusable actions across Sidecar, Window Switcher, display and workspace controls, app and input controls, timed Keep Awake sessions, IP address copying, battery and fan controls, clipboard, disks and Trash, app repair and quitting, guarded Homebrew maintenance, favorite user Launch Items, and physical clean mode. Disk and Xcode cleanup actions open a scan-and-review flow instead of deleting immediately, cancelling an app repair stops its privileged helper operation, and non-cancellable disk and Trash operations finish before reporting their result. Battery actions advertise background execution only when the installed helper can perform it without an administrator prompt. These actions work consistently in shortcuts, gestures, Action Grid, Automation, and Unified Search while preserving live availability checks, confirmations, foreground-only flows, and Run Link restrictions where required.
