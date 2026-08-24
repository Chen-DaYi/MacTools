# Mac Settings Plugin

Mac Settings is a workspace plugin for searching, changing, comparing, and transporting a curated set of settings for the current Mac. The Phase 0 feasibility and safety decisions are recorded in [the catalog audit](../superpowers/specs/2026-08-23-mac-settings-feasibility-audit.md).

## User surfaces

- **Settings workspace:** starts at All Settings, supports category and natural-language search, shows live values and availability, and keeps controls usable in the result rows.
- **Sidebar destinations:** Favorites, Recently Changed, Needs Attention, categories, Profiles, Import, and History.
- **Feature Panel:** exposes up to four ordered favorite controls plus an Open All Settings action.
- **Actions:** opens the workspace, a category, or an exact setting; searches settings; performs explicit Boolean changes through the same verified adapter path; opens a saved profile's compare/apply preview; and rolls back the most recent eligible change.

Rows distinguish loading, applying, active verification, settings that apply on the next relevant use, provider/hardware/permission unavailability, restart or logout requirements, guided-manual settings, and unsupported settings. Guided rows open the narrowest useful System Settings destination and never pretend to be automated.

Three-finger drag, pointer size, keyboard zoom, scroll-gesture zoom, and its Control/Option/Command modifier are direct, profile-eligible controls. The zoom controls dynamically validate Apple's high-level Universal Access runtime functions, which update shortcut and HID gesture state immediately. macOS protects the persisted cursor-size preference, so pointer size requires Full Disk Access and an app relaunch after the one-time authorization. Mac Settings declares Full Disk Access through the common plugin permission contract and derives the card's affected-setting list from every catalog record that declares that requirement; the host renders the same permission section for form and workspace plugins and deduplicates shared capabilities in the General settings permission overview. MacTools disables affected controls and routes both the shared card and inline row actions through one handler until access is available. It then writes and reads back one fixed allowlisted preference key, synchronizes the Universal Access runtime, rebuilds the cursor, and treats WindowServer's active scale as authoritative; this prevents transient-only changes and stale caches from resetting the control. The controls fail closed if persistence or the private runtime implementation changes. Three-finger drag uses the same runtime-validated trackpad backend as System Settings for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.

The 48-entry catalog also includes direct Dock size, launch animation, open-app indicators, Finder safety warnings and folder ordering, and Appearance scroll-bar behavior. True Tone and Night Shift reuse their live canonical providers. Full Keyboard Access, Sticky Keys, Slow Keys, secondary click, scroll speed, Low Power Mode, and Wi-Fi remain guided rows until their device- or release-specific live behavior has a verified adapter.

## Profiles

Profiles use the exported `cc.ggbond.mactools.settings-profile` JSON type. Inclusion is independent from a value: an excluded Boolean and an included Boolean whose desired value is `false` are different states.

Before applying, the plugin shows current and desired values, skips matches, lets the user select individual changes, and creates an immutable plan. Execution reports verified, pending logout/restart, skipped, unavailable, unsupported, verification-unavailable, or failed-and-rolled-back results per setting. A successful plan retains a rollback point for eligible values.

The decoder accepts only the versioned document schema, stable setting IDs, catalog-approved typed values, and bounded metadata. It rejects files larger than 1 MiB, more than 200 entries, arbitrary JSON fields, sensitive settings, and nonportable catalog entries. Unknown future IDs remain in the imported profile with a warning but are never executed. Portable plugin preferences include favorites, density, and profiles; history and local runtime state are excluded.

## Provider reuse

Dark Mode, Dock auto-hide, menu bar auto-hide, Stage Manager, True Tone, and Night Shift writes are delegated to their existing canonical action providers. `PluginActionExecutionHostContext` is intentionally narrow: it supports live action lookup and execution through the host-owned registry/executor, so composed writes retain provider availability and safety behavior.

Profile-backed action references declare `requiresPluginPreferences` during preferences backup. Navigation and explicit typed setting actions are self-contained; history-based Undo is excluded because history is intentionally local and nonportable.

## Development and verification

Generate the project after adding or moving plugin files:

```bash
make generate
```

Build the dynamic plugin target:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacSettingsPlugin -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet
```

Run the focused coverage:

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test -quiet \
  -only-testing:MacToolsTests/SystemSettingCatalogTests \
  -only-testing:MacToolsTests/SystemSettingAdapterTests \
  -only-testing:MacToolsTests/MacSettingsControllerTests \
  -only-testing:MacToolsTests/SystemSettingsProfileTests \
  -only-testing:MacToolsTests/MacSettingsPluginTests \
  -only-testing:MacToolsTests/PluginHostActionExecutionContextTests
```
