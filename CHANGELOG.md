# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

Pending release notes live in `changes/unreleased/*.md` and are compiled during
the app and plugin release processes.

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
