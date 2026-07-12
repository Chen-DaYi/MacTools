# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Pending release notes live in `changes/unreleased/*.md` and are compiled during
the app and plugin release processes.

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
