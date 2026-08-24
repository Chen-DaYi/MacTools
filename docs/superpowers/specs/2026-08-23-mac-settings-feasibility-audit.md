# Mac Settings Feasibility Audit

Issue: [#325](https://github.com/ggbond268/MacTools/issues/325)

Audit date: 2026-08-23
Supported baseline: macOS 14.0 and later

## Decision summary

The current release uses a catalog of 48 typed settings. Each entry owns a stable ID, category, value schema, compatibility requirements, read/write/verify adapter, rollback behavior, profile portability, search aliases, and a System Settings destination. The catalog is the source of truth for the workspace, Feature Panel favorites, actions, history, and profiles.

Writes use one of three paths:

1. **Provider** delegates to an existing canonical MacTools action through the host registry and executor. This preserves the original provider's availability, safety, confirmation, and error behavior.
2. **Defaults** writes one curated, allowlisted preference value and reads it back for verification. No arbitrary domain, key, command, or shell payload is accepted.
3. **Guided** or **unsupported** never writes. It explains the limitation and opens the narrowest useful System Settings destination.

The four live accessibility controls dynamically load Apple's high-level Universal Access runtime functions and validate every required symbol. Those functions perform the same active updates as System Settings: cursor changes rebuild WindowServer cursors, keyboard zoom updates the shortcut state, and scroll zoom programs the HID modifier binding. macOS protects the persisted cursor-size preference from ordinary third-party processes, so MacTools requires Full Disk Access and a relaunch before enabling that control. Cursor writes then persist and read back the single allowlisted `com.apple.universalaccess mouseDriverCursorSize` key through `/usr/bin/defaults`, synchronize the Universal Access runtime, and invoke the live setter; no user-controlled domain, key, or command is accepted. Reads and verification use WindowServer's active scale as the authority because in-process preference reads can remain stale. If either persistence or the private runtime implementation fails, the write fails closed instead of accepting a transient-only update.

The activation audit distinguishes three outcomes in the UI: active and verified now, saved and applied on the next relevant use, and saved but requiring an app restart or login. A preference read-back alone is never used as evidence that an immediately visible system behavior changed when a separate live runtime state is available.

The audit rejected a host-wide “system setting contribution” protocol for this phase. Existing providers already publish canonical actions, so a narrow optional action-execution context is sufficient and keeps the PluginKit witness table compatible. A future contribution protocol is justified only when another consumer needs typed setting schemas and read/verify semantics, not merely action execution.

## Catalog audit

Legend:

- `G14+` means available on the supported macOS 14+ baseline; catalog requirements can add a maximum version later.
- `D` is a curated defaults adapter, `P` is an existing plugin provider, `G` is guided, and `U` is unsupported.
- `R/W/V` describes read, write, and verification. `—` means no automated operation.
- All rows require no additional permission unless stated. All values are non-sensitive. Portable rows contain typed values only, never credentials or executable content.

| Stable ID | Class and R/W/V | Gates/provider | Effect and rollback | Profile | System Settings destination |
| --- | --- | --- | --- | --- | --- |
| `accessibility.three-finger-drag` | D live composite; runtime-validated trackpad backend plus multitouch domains/read-back | G14+; runtime class and selectors validated | Immediate hardware update; verified live-state and persistence rollback | Portable Boolean | Accessibility > Pointer Control |
| `accessibility.pointer-size` | D live; allowlisted defaults persistence/read-back plus Universal Access synchronization, high-level setter, and WindowServer active-state read-back | G14+; runtime symbols validated; Full Disk Access and app relaunch | Persistent immediate cursor rebuild; verifies saved and authoritative active scales; rollback | Portable decimal | Accessibility > Display |
| `accessibility.keyboard-zoom` | D live; Universal Access high-level setter/read-back | G14+; runtime symbols validated | Immediate shortcut-state update; verified rollback | Portable Boolean | Accessibility > Zoom |
| `accessibility.scroll-zoom` | D live; Universal Access high-level setter/read-back | G14+; runtime symbols validated | Immediate HID zoom-binding update; verified rollback | Portable Boolean | Accessibility > Zoom |
| `accessibility.scroll-zoom-modifier` | D live; allowlisted Control/Option/Command high-level setter/read-back | G14+; runtime symbols validated | Immediate HID modifier update; verified rollback | Portable choice | Accessibility > Zoom |
| `accessibility.full-keyboard-access` | G; —/—/— | Direct live path not yet validated | Guided; no rollback | Local only, excluded | Accessibility > Keyboard |
| `accessibility.sticky-keys` | G; —/—/— | Direct live path not yet validated | Guided; no rollback | Local only, excluded | Accessibility > Keyboard |
| `accessibility.slow-keys` | G; —/—/— | Direct live path not yet validated | Guided; no rollback | Local only, excluded | Accessibility > Keyboard |
| `input.secondary-click` | G; —/—/— | Coupled device-specific gesture state | Guided; no rollback | Local only, excluded | Trackpad settings |
| `input.scroll-speed` | G; —/—/— | No stable cross-device key | Guided; no rollback | Local only, excluded | Pointer Control settings |
| `input.tap-to-click` | D live composite; runtime-validated trackpad backend plus multitouch domains/read-back | Supported trackpad; G14+ | Immediate hardware update; verifies live behavior and persistence; rollback | Portable Boolean | Trackpad settings |
| `input.natural-scrolling` | D; global defaults/scroll-direction notification/read-back | G14+ | Notification delivered immediately; device behavior remains hardware-dependent; rollback | Portable Boolean | Trackpad settings |
| `input.mouse-tracking-speed` | D; global defaults/same/read-back | Mouse behavior; G14+ | Login may be required because no stable live setter is available; rollback | Portable decimal | Mouse settings |
| `input.trackpad-tracking-speed` | D live; runtime-validated trackpad backend plus global defaults/read-back | Trackpad behavior; G14+ | Immediate hardware update; verifies live speed and persistence; rollback | Portable decimal | Trackpad settings |
| `keyboard.key-repeat` | D; global defaults/same/read-back | G14+ | Logout may be required; rollback | Portable integer | Keyboard settings |
| `keyboard.initial-key-repeat` | D; global defaults/same/read-back | G14+ | Logout may be required; rollback | Portable integer | Keyboard settings |
| `keyboard.function-keys` | D; global defaults/function-key notification/read-back | G14+ | Notification delivered immediately; verified rollback | Portable Boolean | Keyboard settings |
| `finder.show-all-extensions` | D; Finder defaults/same/read-back | G14+ | Finder restart may be required; rollback | Portable Boolean | Finder settings |
| `finder.warn-extension-change` | D; Finder defaults/same/read-back | G14+ | Applies on next rename; rollback | Portable Boolean | Finder settings |
| `finder.warn-empty-trash` | D; Finder defaults/same/read-back | G14+ | Applies on next Empty Trash action; rollback | Portable Boolean | Finder settings |
| `finder.folders-first` | D; Finder defaults/same/read-back | G14+ | Finder restart may be required; rollback | Portable Boolean | Finder settings |
| `finder.show-path-bar` | D; Finder defaults/same/read-back | G14+ | Finder restart may be required; rollback | Portable Boolean | Finder settings |
| `finder.show-status-bar` | D; Finder defaults/same/read-back | G14+ | Finder restart may be required; rollback | Portable Boolean | Finder settings |
| `finder.search-scope` | D; Finder defaults/allowlisted choice/read-back | G14+ | Applies to the next Finder search; rollback | Portable choice | Finder settings |
| `finder.new-window-target` | D; Finder defaults/allowlisted choice/read-back | G14+ | Applies to the next Finder window; rollback | Portable choice | Finder settings |
| `dock.auto-hide` | P; Dock defaults/`auto-hide-dock.set-enabled`/read-back | Provider `auto-hide-dock`; G14+ | Immediate; provider write and verified rollback | Portable Boolean | Desktop & Dock |
| `dock.size` | D; Dock defaults/notification/read-back | G14+ | Immediate Dock update; rollback | Portable decimal | Desktop & Dock |
| `dock.position` | D; Dock defaults/allowlisted choice/read-back | G14+ | Immediate; Dock notification; rollback | Portable choice | Desktop & Dock |
| `dock.magnification` | D; Dock defaults/same/read-back | G14+ | Immediate; Dock notification; rollback | Portable Boolean | Desktop & Dock |
| `dock.magnification-size` | D; Dock defaults/bounded decimal/read-back | G14+ | Immediate; Dock notification; rollback | Portable decimal | Desktop & Dock |
| `dock.minimize-effect` | D; Dock defaults/allowlisted choice/read-back | G14+ | Immediate; Dock notification; rollback | Portable choice | Desktop & Dock |
| `dock.show-recents` | D; Dock defaults/same/read-back | G14+ | Immediate; Dock notification; rollback | Portable Boolean | Desktop & Dock |
| `dock.minimize-into-application` | D; Dock defaults/same/read-back | G14+ | Immediate; Dock notification; rollback | Portable Boolean | Desktop & Dock |
| `dock.animate-opening-applications` | D; Dock defaults/same/read-back | G14+ | Immediate; Dock notification; rollback | Portable Boolean | Desktop & Dock |
| `dock.show-open-indicators` | D; Dock defaults/same/read-back | G14+ | Immediate; Dock notification; rollback | Portable Boolean | Desktop & Dock |
| `screenshots.format` | D; screencapture defaults/allowlisted choice/read-back | G14+ | Applies to new captures; rollback | Portable choice | Keyboard > Screenshots |
| `screenshots.floating-thumbnail` | D; screencapture defaults/same/read-back | G14+ | Applies to new captures; rollback | Portable Boolean | Keyboard > Screenshots |
| `screenshots.window-shadow` | D; inverted screencapture Boolean/read-back | G14+ | Applies to new captures; rollback | Portable Boolean | Keyboard > Screenshots |
| `screenshots.destination` | D; screencapture path/local directory/read-back | Local directory must remain valid | Applies to new captures; rollback | Device-specific, excluded | Keyboard > Screenshots |
| `appearance.dark-mode` | P; global defaults/`appearance.set-enabled`/read-back | Provider `appearance`; G14+ | Immediate; provider write and verified rollback | Portable Boolean | Appearance |
| `appearance.show-scroll-bars` | D; global defaults/allowlisted choice/read-back | G14+ | Applies to supporting apps on next relevant use; rollback | Portable choice | Appearance |
| `appearance.scroll-bar-click-jumps-to-spot` | D; global defaults/read-back | G14+ | Applies on next scroll-bar click; rollback | Portable Boolean | Appearance |
| `display.true-tone` | P; live action state/`display-true-color.set-enabled`/live action state | Provider `display-true-color`; supported display | Immediate provider update; verified rollback | Portable Boolean | Displays |
| `display.night-shift` | P; live action state/`night-shift.set-enabled`/live action state | Provider `night-shift`; supported display | Immediate provider update; verified rollback | Portable Boolean | Displays |
| `power.low-power-mode` | G; —/—/— | Choices vary by model and power source | Guided; no rollback | Local only, excluded | Battery settings |
| `network.wifi` | G; —/—/— | Per-service state and credentials remain outside profiles | Guided; no rollback | Local only, excluded | Network settings |
| `desktop.menu-bar-auto-hide` | P; global defaults/`auto-hide-menu-bar.set-enabled`/read-back | Provider `auto-hide-menu-bar`; G14+ | Immediate; provider write and verified rollback | Portable Boolean | Desktop & Dock |
| `desktop.stage-manager` | P; WindowManager defaults/`stage-manager.set-enabled`/read-back | Provider `stage-manager`; G14+ | Immediate; provider write and verified rollback | Portable Boolean | Desktop & Dock |

## Candidates not admitted

- Hot Corners, Accessibility zoom composition, and several pointer/accessibility toggles have coupled or OS-build-dependent backing state. Secondary click, Full Keyboard Access, Sticky Keys, Slow Keys, scroll speed, Low Power Mode, and Wi-Fi are searchable guided rows until stable, testable live adapters exist. Three-finger drag, pointer size, and keyboard zoom were admitted after their dedicated preferences were confirmed on the supported implementation path.
- Hidden files, automatic app termination, and other expert defaults were deferred because the first release prioritizes discoverable settings with clear effects and safe reversal.
- Hardware identifiers, display IDs, local paths, permissions, secrets, and credentials are not portable profile values. The screenshot destination is explicitly device-specific and cannot be saved to or imported from a portable profile.
- Arbitrary preference domains, keys, commands, scripts, and executable profile fields are out of scope and rejected by the profile decoder.

## Runtime and safety conclusions

- Initial reads are incremental and cancellable. Getters use cached snapshots; external preference, app-activation, trackpad, Dock, appearance, and Stage Manager notifications schedule debounced refreshes.
- A write is not recorded as successful history until verification succeeds. A mismatch remains visible and triggers best-effort rollback when the old value is known.
- Profiles are immutable apply plans: current vs desired values are computed first, already-matching rows are skipped, and the user selects changes before execution. Results are structured per setting and a rollback point captures eligible old values.
- Unknown imported IDs are preserved for forward compatibility but never planned for execution. Files are limited to 1 MiB and 200 entries, and strict JSON keys prevent executable extensions.
- Organization-signed profiles remain a future proposal. The current format has versioning and a stable typed schema but deliberately defines no signature or policy-management semantics.
