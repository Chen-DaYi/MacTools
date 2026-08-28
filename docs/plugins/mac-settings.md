# Mac Settings Plugin

Mac Settings is a workspace plugin for searching, changing, comparing, and transporting a curated set of settings for the current Mac. The Phase 0 feasibility and safety decisions are recorded in [the catalog audit](../superpowers/specs/2026-08-23-mac-settings-feasibility-audit.md).

## User surfaces

- **Settings palette:** starts with a focused global search field and keeps live controls directly in the results. With an empty query it shows the complete catalog in one continuous list with lightweight category headings; typing switches to one flat ranked result list.
- **Secondary tools:** Pinned, Recently Changed, Needs Attention, Profiles, Import, History, and manual refresh live in the overflow menu instead of a second settings sidebar. Profile, import, and history pages provide an explicit return to the palette.
- **Feature Panel:** exposes up to four ordered favorite controls plus an Open All Settings action.
- **Actions:** opens the workspace, a category, or an exact setting; searches settings; performs explicit Boolean changes through the same verified adapter path; opens a saved profile's compare/apply preview; and rolls back the most recent eligible change.

Rows distinguish loading, applying, exceptional verification states, settings that apply on the next relevant use, provider/hardware/permission unavailability, restart or logout requirements, and unsupported settings. Category metadata appears in search and special scoped results but is omitted when the category heading already supplies that context. Descriptions, implementation details, pinning, and System Settings links live in each row's expandable details. If a guarded runtime adapter cannot read or verify its capability on the current macOS release or hardware, that row exposes its narrow System Settings destination as a fallback.

Three-finger drag, pointer size, keyboard zoom, scroll-gesture zoom, and its Control/Option/Command modifier are direct, profile-eligible controls. The zoom controls dynamically validate Apple's high-level Universal Access runtime functions, which update shortcut and HID gesture state immediately. macOS protects the persisted cursor-size preference, so pointer size requires Full Disk Access and an app relaunch after the one-time authorization. Mac Settings declares Full Disk Access through the common plugin permission contract and derives the card's affected-setting list from every catalog record that declares that requirement; the host renders the same permission section for form and workspace plugins and deduplicates shared capabilities in the General settings permission overview. MacTools disables affected controls and routes both the shared card and inline row actions through one handler until access is available. It then writes and reads back one fixed allowlisted preference key, synchronizes the Universal Access runtime, rebuilds the cursor, and treats WindowServer's active scale as authoritative; this prevents transient-only changes and stale caches from resetting the control. The controls fail closed if persistence or the private runtime implementation changes. Three-finger drag uses the same runtime-validated trackpad backend as System Settings for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.

The 47-entry catalog also includes direct Dock size, launch animation, open-app indicators, Finder safety warnings and folder ordering, and Appearance scroll-bar behavior. True Tone and Night Shift reuse their live canonical providers. Full Keyboard Access, Sticky Keys, and Slow Keys use guarded Universal Access runtime setters. Secondary click is a verified gesture picker, while trackpad and mouse scroll speeds use separate hardware backends. Wi-Fi power and Low Power Mode are intentionally omitted because they are ordinary transient, device-related controls with easy access in macOS Control Center and do not belong in durable Mac configuration profiles.

## Profiles

Profiles use the exported `cc.ggbond.mactools.settings-profile` JSON type. Inclusion is independent from a value: an excluded Boolean and an included Boolean whose desired value is `false` are different states.

Before applying, the plugin shows current and desired values, skips matches, lets the user select individual changes, and creates an immutable plan. Execution reports verified, pending logout/restart, skipped, unavailable, unsupported, verification-unavailable, or failed-and-rolled-back results per setting. A successful plan retains a rollback point for eligible values.

The decoder accepts only the versioned document schema, stable setting IDs, catalog-approved typed values, and bounded metadata. It rejects files larger than 1 MiB, more than 200 entries, arbitrary JSON fields, sensitive settings, and nonportable catalog entries. Unknown future IDs remain in the imported profile with a warning but are never executed. Portable plugin preferences include pinned settings and profiles; the legacy density field remains serialized for compatibility, while history and local runtime state are excluded.

## Provider reuse

The source manifest publishes the upstream catalog's localized product, privacy, setup, and action descriptors. Its eight stable action definitions are covered by the shared manifest/runtime consistency test. Full Disk Access is conditional on pointer-size persistence and is explained in setup guidance rather than declared as a requirement for every action; provider-backed controls retain their providers' own permission checks.

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
