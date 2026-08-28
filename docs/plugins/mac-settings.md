# Mac Settings Plugin

Mac Settings is a workspace plugin for searching, changing, comparing, and transporting a curated set of settings for the current Mac. The Phase 0 feasibility and safety decisions are recorded in [the catalog audit](../superpowers/specs/2026-08-23-mac-settings-feasibility-audit.md).

## User surfaces

- **Settings palette:** starts with a focused global search field and keeps live controls directly in the results. With an empty query it shows the complete catalog in one continuous list with lightweight category headings; typing switches to one flat ranked result list.
- **Secondary tools:** Pinned, Recently Changed, Needs Attention, Profiles, Import, History, and manual refresh live in the overflow menu instead of a second settings sidebar. Profile, import, and history pages provide an explicit return to the palette.
- **Feature Panel:** exposes up to four ordered favorite controls plus an Open All Settings action.
- **Actions:** opens the workspace, a category, or an exact setting; searches settings; performs explicit Boolean changes through the same verified adapter path; opens a saved profile's compare/apply preview; and rolls back the most recent eligible change.

Rows distinguish loading, applying, exceptional verification states, settings that apply on the next relevant use, provider/hardware/permission unavailability, restart or logout requirements, and unsupported settings. Category metadata appears in search and special scoped results but is omitted when the category heading already supplies that context. Descriptions, implementation details, pinning, and System Settings links live in each row's expandable details. If a guarded runtime adapter cannot read or verify its capability on the current macOS release or hardware, that row exposes its narrow System Settings destination as a fallback.

Three-finger drag, pointer size, keyboard zoom, scroll-gesture zoom, and its Control/Option/Command modifier are direct, profile-eligible controls. The zoom controls dynamically validate Apple's high-level Universal Access runtime functions, which update shortcut and HID gesture state immediately. macOS protects the persisted cursor-size preference, so pointer size requires Full Disk Access and an app relaunch after the one-time authorization. Mac Settings declares Full Disk Access through the common plugin permission contract and derives the card's affected-setting list from every catalog record that declares that requirement; the host renders the same permission section for form and workspace plugins and deduplicates shared capabilities in the General settings permission overview. MacTools disables affected controls and routes both the shared card and inline row actions through one handler until access is available. It then writes and reads back one fixed allowlisted preference key, synchronizes the Universal Access runtime, rebuilds the cursor, and treats WindowServer's active scale as authoritative; this prevents transient-only changes and stale caches from resetting the control. The controls fail closed if persistence or the private runtime implementation changes. Three-finger drag uses the same runtime-validated trackpad backend as System Settings for an immediate hardware update, then verifies both built-in and Bluetooth preference domains.

The initial catalog exposes 39 settings, including Dock size, launch animation, open-app indicators, Finder safety warnings and folder ordering, and Appearance scroll-bar behavior. True Tone reuses its live canonical provider. Trackpad and mouse scroll speeds use separate hardware backends; mouse tracking speed explicitly requires logout. The compact Feature Panel uses a complete selection list for controls with more than three choices.

Full Keyboard Access, Sticky Keys, Slow Keys, secondary click, standard function keys, screenshot destination, Night Shift, and menu bar auto-hide are deferred in this workspace. Their definitions and implementations remain in source, but their adapters are excluded from the production catalog. This also excludes them from search, favorites, actions, new profile drafts, and built-in templates; it does not disable independent plugins that already provide some of these features. The [deferred backlog](../superpowers/specs/2026-08-28-mac-settings-catalog-review.md#deferred-backlog) records each stable ID, reason, and evidence required for a future version.

Wi-Fi power and Low Power Mode are intentionally omitted because they are ordinary transient, device-related controls with easy access in macOS Control Center and do not belong in durable Mac configuration profiles.

## Finder controls

Show All Filename Extensions writes `AppleShowAllExtensions` in the global preference domain. Reads honor an existing Finder-specific override; an explicit change removes that override so it cannot shadow the global setting. Local snapshots preserve both domains, including absent keys, for exact Undo. No filenames or per-file extension flags are changed. Persistence is verified, but Finder may need relaunching; the plugin does not restart Finder automatically or claim to have checked visible filenames.

New Finder Window Destination supports Recents, Home, Desktop, Documents, Computer, iCloud Drive, and a custom folder. It reads and snapshots `NewWindowTarget` and `NewWindowTargetPath` together. Unknown native targets are displayed without becoming writable choices, and existing custom paths remain readable even when the folder is disconnected. New selections validate local directory URLs and directory availability immediately before writing. iCloud Drive requires the local iCloud folder to be available. Verification checks both stored fields; Undo restores their original values or absence without reconstructing the old path.

Only named destinations may enter portable profiles. Custom paths remain in local state/history; profile drafts do not copy them, the profile editor offers named choices only, and import/export/execution reject local URLs or unknown destination codes. Preview and execution also check paired-path state before declaring a match. Local history and profile rollback points retain complete snapshots across serialization. Older Finder history without those snapshots fails safely instead of guessing a path or original key presence.

The native preference store uses exact-domain Core Foundation reads and writes rather than launching `defaults` processes. This follows Apple's [exact-domain preference API](https://developer.apple.com/documentation/corefoundation/cfpreferencescopyvalue(_:_:_:_:)) and [global application domain](https://developer.apple.com/documentation/corefoundation/kcfpreferencesanyapplication). The [nix-darwin Finder implementation](https://github.com/nix-darwin/nix-darwin/blob/master/modules/system/defaults/finder.nix) provides implementation precedent for destination codes and the paired path, not a guarantee of compatibility on every macOS release.

## Profiles

Profiles use the exported `cc.ggbond.mactools.settings-profile` JSON type. Inclusion is independent from a value: an excluded Boolean and an included Boolean whose desired value is `false` are different states.

Before showing a comparison, the plugin reads the profile's current values asynchronously; cached defaults are not used as evidence of a match. It skips matches, lets the user select individual changes, and creates an immutable plan. Matches are checked again at execution time: a changed value requires another preview and is never silently selected. Execution reports verified, pending logout/restart, skipped, cancelled, unavailable, unsupported, verification-unavailable, or failed-and-rolled-back results per setting. A successful plan retains a rollback point for eligible values.

Deactivation cancels pending preview, inline-write, profile-apply, and rollback tasks. No new setting operation starts after cancellation. A write already in progress is allowed to settle through verification or recovery, and its result is retained. Rollback has its own visible outcomes; failures remain in Needs Attention across refreshes, and retries operate only on settings not yet restored. Verified restorations are recorded in local history.

The decoder accepts only the versioned document schema, stable setting IDs, catalog-approved typed values, and bounded metadata. It rejects files larger than 1 MiB, more than 200 entries, arbitrary JSON fields, sensitive settings, and nonportable catalog entries. Unknown future IDs and valid deferred entries remain in imported profiles with warnings but are never executed. Editing the available controls preserves those entries. Deferred definitions still enforce value and portability restrictions, so hiding screenshot destination does not make local paths portable. Portable plugin preferences include pinned settings and profiles; the legacy density field remains serialized for compatibility, while history and local runtime state are excluded.

## Provider reuse

The source manifest publishes the upstream catalog's localized product, privacy, setup, and action descriptors. Its eight stable action definitions are covered by the shared manifest/runtime consistency test. Full Disk Access is conditional on pointer-size persistence and is explained in setup guidance rather than declared as a requirement for every action; provider-backed controls retain their providers' own permission checks.

Dark Mode, Dock auto-hide, Stage Manager, and True Tone writes are delegated to their existing canonical action providers. The retained but deferred menu bar auto-hide and Night Shift implementations also use their canonical providers. `PluginActionExecutionHostContext` is intentionally narrow: it supports live action lookup and execution through the host-owned registry/executor, so composed writes retain provider availability and safety behavior.

The bridge first ships in host 1.2.1, so Mac Settings requires at least that host version even though the PluginKit version remains 5. Its public bridge types are included in the minimum-host compatibility inventory. Explicit Automation permission buttons open System Settings; passive permission guidance retains the current page.

The [47-setting release review](../superpowers/specs/2026-08-28-mac-settings-catalog-review.md) records the accepted 39-included/8-deferred scope, the backlog for future planning, and outstanding live-validation gates. The Finder implementations and exact rollback model are now in place. Inclusion and passing automated tests are not proof of live macOS compatibility; visible filenames and actual new-window destinations still need the recorded checks before release.

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
