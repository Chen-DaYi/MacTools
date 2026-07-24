# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Pending release notes live in `changes/unreleased/*.md` and are compiled during
the app and plugin release processes.

## [plugins-1.1.3] - 2026-07-24

### Added

- Keep Awake can optionally keep a Mac laptop running with its lid closed. The preference can be enabled on battery, waits for external power, and activates automatically when power connects.

### Changed

- IP Check now performs a lightweight local and public IPv4 refresh whenever its Feature Panel or settings page opens.

### Fixed

- Sidecar device settings now keep connection options and shortcuts readable in narrow Settings windows.

## [v1.1.3] - 2026-07-24

### Added

- General Settings now offers optional global shortcuts to toggle Dashboard and Feature Panel.
- The Feature Panel now copies button and switch subtitles, including either inline IP Check address, on double-click and briefly confirms successful copies.
- Settings now provides Back and Forward navigation with ⌘[ and ⌘], including exact restoration of Plugin subpages.
- Menu-bar panels and Settings now support standard local shortcuts for dismissal, Settings, and search.

### Fixed

- Grouped shortcut controls now stay readable and inside their settings card when labels are long or many actions are shown.

## [v1.1.2] - 2026-07-20

### Added

- Use Command-number shortcuts to switch menu-bar panels and jump among the main Settings pages.
- Show, hide, and reorder Dashboard components and Feature Panel actions independently. Hiding affects only that surface and does not stop a plugin’s background behavior.
- Manage installation, updates, and removal in Marketplace, or open plugin settings and uninstall directly from a layout row. Repeated uninstall confirmations can be paused for the current Settings session.
- Existing global layouts and older backups migrate safely to both surfaces. New backups preserve independent layouts while retaining a conservative legacy projection for older app versions.
- Plugins previously disabled from Installed load after upgrade but remain hidden on supported surfaces. Downgrading cannot restore the former disabled lifecycle state, so uninstall plugins you do not want running.
- The online icon gallery now includes a curated set of static icons across every category and marks animated icons with a clear badge for easier browsing.

### Changed

- Background-aware plugins can now pause nonessential work while the session is locked or the Mac is asleep.
- Animated items in the online icon gallery now use a compact play indicator that leaves more of each icon visible.
- Menu bar icon settings now show the current selection in a compact preview, play animations at their default speed, and omit playback controls, contrast warnings, and the recent-icons list.

### Fixed

- Feature-panel switches now update reliably after being clicked on macOS 27.
- Importing menu bar icons now preserves their original colors and transparency, preventing white artwork on transparent PNGs from disappearing.
- Monochrome icons from the online gallery now automatically adapt to light and dark menu bar backgrounds while colorful icons keep their original appearance.

## [plugins-1.1.2] - 2026-07-20

### Changed

- Use clear visibility controls when choosing System Status metrics for the panel or menu bar.

### Fixed

- Device Battery now avoids unnecessary Bluetooth scans when its widget and low-battery alerts are inactive.
- Keep Fan Control’s faster refresh limited to its visible, expanded panel, and keep Hide Menu Bar Icons running when it is hidden from a layout.

## [plugins-1.1.1] - 2026-07-17

### Added

- Connect nearby Sidecar-compatible displays with direct actions and status indicators. Switching disconnects the current display before connecting another.
- Save per-display connection priorities and shortcuts, with a priority-aware shortcut that connects the first available display.
- Request wired-only transport without falling back to Wi-Fi. Automatic Sidecar controls remain available when wired-only transport is unsupported.
- Sidecar shortcuts now use MacTools-wide conflict validation, imported settings are normalized, and unavailable states stay distinct from connectable displays. Panel feedback clears on close or before it becomes stale.

### Fixed

- Eject Disks now detects all visible ejectable mounts when the panel opens, including disk images, fixed external drives, and network volumes.
- Homebrew, Mouse Enhancer, Activity Bar, System Status, and Window Switcher controls now use the selected app language.
- Quit Apps now groups multiple running instances of the same app into one entry, preventing blank or misplaced cells while still quitting every instance selected.
- Finder Right Click now offers path-copy actions on window backgrounds and copies the current folder instead of requiring a selected item.

## [v1.1.1] - 2026-07-16

### Added

- MacTools preferences can be exported and imported as a versioned JSON backup, including app preferences, plugin display settings, and shortcuts. During import, missing plugins can be installed from the verified catalog.
- The website now provides a bilingual privacy policy explaining MacTools' local-first data handling, system permissions, and network-dependent features.

### Changed

- The feature and component panel switcher is now centered in a capsule-shaped toolbar control, with matching hover shapes for toolbar actions.
- Plugin Marketplace name sorting now follows the language selected in MacTools, with localized ascending and descending labels.
- MacTools can now assign a global shortcut to open its Settings window, and the menu-bar panel no longer shows a misleading dashboard focus outline while viewing features.
- Portable plugin settings can now opt in to preference backup and restore, including Sidecar display priority and shortcut configuration.

### Fixed

- Secondary menu-bar lists now open on the available side of the panel and switch to an in-panel view when screen space is limited.
- Feature-panel action buttons now match switch widths, preserve label spacing, and expose full long labels in tooltips.
- Plugin update progress now advances after each plugin finishes during automatic and manual bulk updates.
- Language names in Settings now remain readable instead of being truncated.
- Right-clicking the menu bar icon now opens the intended panel reliably on macOS 27 without briefly showing the primary panel or closing immediately.
- Shortcut recording now accepts F1-F12 as standalone shortcuts, including the shortcut for opening Settings, and explains when other keys require a modifier.
- The website download now points to the latest stable MacTools DMG instead of a plugin batch release. The Homebrew install command adapts to light and dark appearance and keeps its copy action compact on phones.

## [v1.1.0] - 2026-07-12

### Added

- The plugin marketplace can sort by install status (not installed first, or installed first with updates prioritized) or by name (A–Z / Z–A).

### Changed

- Placed plugin-specific settings between permission and shortcut sections for a more natural configuration flow.
- The in-app update dialog now includes plugin changes released since the previous app version.
- Changing the app language now refreshes all Settings and plugin controls immediately without requiring a restart.
- The language picker now shows each option in the system language alongside its native name.
- New app versions use a PluginKit-versioned plugin catalog and update installed plugins before loading them, while older app versions continue using the legacy catalog.

### Fixed

- Custom and gallery menu bar icons now use one standard height and content inset with consistent settings previews.

## [plugins-1.1.0] - 2026-07-12

### Added

- Device Battery can show trusted iPhone, iPad, iPod touch, Vision Pro, and paired Apple Watch battery and charging status over USB or Wi-Fi.
- Keep Awake can optionally keep the display on for every session through its plugin settings and shows an indicator while that mode is active.

### Changed

- Refined the native window switcher overlay and added editable, stable single-key app shortcuts.
- Device Battery now refreshes Apple mobile devices less often while the component panel is hidden.
- All plugin packages are rebuilt for PluginKit 3 and published together in a versioned catalog so they remain compatible with the new app runtime.

### Fixed

- Eject Disks no longer treats internal system or non-ejectable volumes as removable disks.
- Translator source text no longer overlaps the copy and speech actions when the text spans multiple lines.

## [v1.0.31] - 2026-07-09

### Changed

- Improved the menu bar icon settings previews so uploaded and online icons are easier to inspect.

## [plugins-1.0.32] - 2026-07-09

### Added

- System Status now includes settings for arranging component-panel metrics and optional compact menu bar metrics.
- Added Window Switcher for shortcut-driven window switching with direct cycling, key-based selection, configurable ordering, stable key hints, and hover quit buttons.

### Fixed

- Activity Bar now includes Cursor coding activity in AI work summaries and coding tool trends.
- Activity Bar now listens for installed AI hooks independently of Input Monitoring tracking.
- Activity Bar can now uninstall the AI activity hooks it adds for Claude Code, Cursor, and Codex.
- Battery Charge Limit now prefers the system charge ceiling path when available, uses the correct macOS 26 charging key, and verifies SMC writes to reduce USB-C display disconnects when charging stops at the limit.
- System Status now reports total GPU usage from the accelerator's total activity metric instead of pipeline-specific counters, avoiding false 100% history samples.
- Translator service order and enabled-state changes now persist immediately.

## [v1.0.30] - 2026-07-07

### Fixed

- Reduce unnecessary menu bar refresh work when plugins report state changes, keeping panels steadier during frequent updates.

## [plugins-1.0.31] - 2026-07-07

### Added

- Add a Homebrew management plugin for browsing packages, installing and upgrading formulae, and running diagnostics from the menu bar and settings.

### Fixed

- Hide Menu Bar Icons no longer quits after Accessibility is granted before Screen Recording is approved.
- Hide Menu Bar Icons now keeps the divider where you drag it instead of snapping it back next to the MacTools icon.
- Keep Awake now restores permanent sessions after restarting MacTools.

## [v1.0.29] - 2026-07-05

### Fixed

- Kept panel position stable and feature panel height accurate as controls expand.

## [plugins-1.0.30] - 2026-07-05

### Changed

- Stop Battery Charge Limit background monitoring while the charging limit is disabled.
- Pause Menu Bar Hidden background observers when the feature is hidden or not actively in use.
- Reduce System Status background sampling to lower idle energy use while keeping foreground updates responsive.

### Fixed

- Prevent repeated low-battery notifications when device battery readings switch sources or briefly disappear.
- Refresh Empty Trash availability when opening the feature panel.
- Fixed Mouse Enhancer settings switches rendering incorrectly on first open.
- Avoid administrator password prompts on quit when Fan Control or Battery Charge Limit did not apply SMC changes.

## [v1.0.28] - 2026-07-03

### Fixed

- Finder right-click menu items now stay hidden while the Right Click plugin is disabled.

### Maintenance

- App release notes now come from concise changelog fragments that are compiled into CHANGELOG.md during release.

## [plugins-1.0.29] - 2026-07-03

### Added

- Added Mouse Enhancer, a mouse and trackpad controls plugin with separate horizontal and vertical scroll reversing plus trackpad-tap middle-click simulation.

### Fixed

- Right Click now keeps Finder extension menu visibility aligned with the plugin's enabled state.

### Maintenance

- Plugin batch release notes now come from plugin changelog fragments compiled into CHANGELOG.md during release.
