# Issue #238: Command-K App Settings and Plugin Visibility Implementation Plan

Issue: [#238 — Expand Command-K with app setting and plugin visibility commands](https://github.com/ggbond268/MacTools/issues/238)

Baseline: `origin/main` at `4676e77` (`Merge pull request #239 from xcv58/codex/global-command-palette`), inspected on 2026-08-04.

## Outcome

Command-K will gain an explicit app/host command catalog that owns:

- the existing Dashboard and Feature Panel presentation commands;
- explicit System, Dark, and Light appearance setters;
- state-aware Enable/Disable Launch at Login commands; and
- host-generated Show/Hide commands for every installed plugin surface.

Plugin-owned commands remain opt-in through `PluginCommandProviding`. Settings that require a value, path, shortcut recorder, permission flow, uninstall flow, or complex editor remain navigation results.

The implementation must not infer Command-K commands by iterating every `AppShortcutAction`, and it must not add any new global shortcuts or change the PluginKit ABI.

## Current State

The merged unified search implementation has the right extension points, but four details need to change:

1. `MacToolsSearchIndexBuilder` currently scans `AppShortcutAction.allCases` and uses `isCommandPaletteSearchEligible` to create app commands. This couples the command palette to the configurable global-shortcut catalog.
2. `MacToolsSearchAction.appCommand` carries an `AppShortcutAction`, so it cannot represent appearance, launch-at-login, or per-plugin visibility setters.
3. `UnifiedSearchPaletteModel` observes only `PluginHost`. It does not observe `LaunchAtLoginController` or appearance preference changes.
4. Every successful command dismisses the palette. That prevents a state-setting command from immediately replacing itself with the newly applicable inverse command.

Useful existing behavior to preserve:

- `PluginHost.performCommand(pluginID:expectedDefinition:)` revalidates plugin commands before execution.
- `PluginHost.setPluginVisible(_:id:on:)` already writes through `PluginDisplayPreferencesStore` and synchronously rebuilds the host projections used by Settings.
- `LaunchAtLoginController.setEnabled(_:)` already owns ServiceManagement calls, rollback, logging, and user-facing errors.
- `AppAppearancePreference` already owns the stored key and application of `NSAppearance`.
- `UnifiedSearchPaletteView` already has one confirmation path shared by mouse, Return, and Command-number activation.

## Design Decisions

### 1. Make palette ownership explicit

Add an app-local command model in a new `Sources/App/AppHostCommands.swift` file:

```swift
struct AppHostCommandDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let keywords: [String]
    let systemImage: String
    let confirmation: MacToolsCommandConfirmation?
    let action: AppHostCommandAction
}

enum AppHostCommandAction: Hashable {
    case appShortcut(AppShortcutAction)
    case setAppearance(AppAppearancePreference)
    case setLaunchAtLogin(Bool)
    case setPluginVisibility(
        pluginID: String,
        surface: PluginDisplaySurface,
        isVisible: Bool
    )
}
```

`AppHostCommandCatalog` will explicitly declare the two existing presentation commands by wrapping `.toggleDashboard` and `.toggleFeaturePanel`. It will not scan `AppShortcutAction.allCases`. Adding a future global shortcut therefore does not create a palette command, and adding a future palette command does not register a global shortcut.

Remove `AppShortcutAction.isCommandPaletteSearchEligible`. Expose the two deliberately shared actions from the new catalog as a fixed list only where the General > Keyboard Shortcuts search result needs their keywords.

Use an app-local `MacToolsCommandConfirmation` value in search results. Convert `PluginCommandDefinition.Confirmation` when indexing plugin commands. This keeps the new app/host model independent of a plugin-named nested type without changing the public PluginKit API.

### 2. Separate declared commands from currently applicable commands

The fixed catalog declares seven commands with stable semantic IDs:

- `app-command.toggle-dashboard`
- `app-command.toggle-feature-panel`
- `app-command.appearance.system`
- `app-command.appearance.dark`
- `app-command.appearance.light`
- `app-command.launch-at-login.enable`
- `app-command.launch-at-login.disable`

The catalog derives an applicable snapshot from live state:

- Dashboard and Feature Panel presentation commands are always applicable.
- The appearance command whose target equals `AppAppearancePreference.stored(in:)` is omitted; the other two are indexed. Across the three possible current states, System, Dark, and Light are all explicit catalog commands, but Command-K never offers a no-op setter.
- Exactly one launch-at-login command is indexed, based on `LaunchAtLoginController.isEnabled`.
- Plugin visibility commands are generated from each surface's visible and hidden `PluginSurfaceLayoutItem` arrays. A visible item gets only Hide; a hidden item gets only Show.

Dynamic visibility IDs include the plugin ID, surface, and desired state:

```text
host-command.plugin-visibility.<plugin-id>.dashboard.show
host-command.plugin-visibility.<plugin-id>.dashboard.hide
host-command.plugin-visibility.<plugin-id>.feature-panel.show
host-command.plugin-visibility.<plugin-id>.feature-panel.hide
```

Generate Dashboard commands only from `dashboardLayoutItems` and `dashboardHiddenLayoutItems`, and Feature Panel commands only from the corresponding Feature Panel arrays. These projections already exclude unsupported surfaces and unavailable/incompatible plugin packages, so plugins need no new protocol conformance.

### 3. Revalidate the exact live definition before execution

Add an `AppHostCommandContext`, scoped to `@MainActor`, containing:

- `PluginHost`;
- `LaunchAtLoginController`; and
- the `UserDefaults` instance used for `AppAppearancePreference`.

`AppHostCommandExecutor.perform(expectedDefinition:context:)` must rebuild the applicable catalog and require an exact matching definition before mutating state. This mirrors the stale-definition defense already used for `PluginCommandProviding` and covers:

- a plugin being removed while its result is visible;
- visibility changing through another host path;
- launch-at-login changing in System Settings; and
- a runtime locale change altering command metadata.

Execution reuses existing owners:

- presentation: `PluginHost.performAppCommand(_:)` for the two explicitly cataloged shortcut actions;
- appearance: a shared `AppAppearancePreference.storeAndApply(in:)` helper that writes the existing key and calls `apply()`;
- launch at login: `LaunchAtLoginController.setEnabled(_:)`, with success determined by the controller's post-call `isEnabled` value; and
- visibility: `PluginHost.setPluginVisible(_:id:on:)`, followed by a live projection check that the requested state was reached.

Do not call `PluginDisplayPreferencesStore`, `SMAppService`, or `NSApp.appearance` directly from the palette.

### 4. Return an execution disposition

Use a typed result rather than a bare success Boolean:

```swift
enum AppHostCommandExecutionResult: Equatable {
    case performed(AppHostCommandContinuation)
    case unavailable
    case failed
}

enum AppHostCommandContinuation: Equatable {
    case dismissPalette
    case refreshIndex
}
```

The two presentation commands return `.dismissPalette`, preserving current behavior. Appearance, launch-at-login, and visibility setters return `.refreshIndex` on success. Unavailable or failed commands also keep the palette open and refresh it.

This makes state changes visible immediately:

- Enable Launch at Login becomes Disable Launch at Login;
- Hide a plugin becomes Show that plugin on the same surface; and
- the selected appearance setter disappears because it is now a no-op.

Plugin-provided commands keep their existing execution and dismissal path.

### 5. Use the same appearance store in Settings and Command-K

Add `AppAppearancePreference.storeAndApply(in:)`. Update the General Settings appearance binding to use this helper instead of independently assigning the raw value and then calling `apply()`.

Make the appearance `UserDefaults` dependency explicit at the composition boundary:

- `AppWindowRouter` accepts `appearanceUserDefaults`, defaulting to `.standard` for existing call sites;
- `SettingsView`/`GeneralSettingsView` initialize `@AppStorage` with that store; and
- both embedded and standalone palette views receive the same store and `LaunchAtLoginController`.

Tests can then use a temporary suite and never change the user's actual appearance preference.

### 6. Observe all state that affects applicability

Extend `UnifiedSearchPaletteModel` to hold the app/host command context and rebuild from:

- `PluginHost.objectWillChange`;
- `LaunchAtLoginController.objectWillChange`; and
- `AppAppearancePreference.didChangeNotification`.

Keep the current coalesced `Task.yield()` rebuild behavior so a publisher's `objectWillChange` is followed by the updated value before indexing.

Before the palette's first build and on an explicit refresh, call `LaunchAtLoginController.refreshStatus()` so an external System Settings change is reflected. Do not perform filesystem, plugin, or network scans from the index builder.

`MacToolsSearchIndexBuilder` should accept an already-derived `[AppHostCommandDefinition]`. It remains responsible for converting definitions into `MacToolsSearchResult`, while catalog state and execution remain outside the indexer.

## Search and Localization Details

Add localized command titles, descriptions, and dynamic Show/Hide formats to `Sources/Resources/Localization/Search.xcstrings`. Required key groups:

- `search.command.appearance.{system,dark,light}.{title,description}`
- `search.command.launchAtLogin.{enable,disable}.{title,description}`
- `search.command.pluginVisibility.{show,hide}.{titleFormat,descriptionFormat}`

Reuse existing localized surface names from `Settings.xcstrings` and localized plugin titles from the host projections. Use `eye` for Show, `eye.slash` for Hide, `circle.lefthalf.filled` for appearance, and `power` for launch at login.

Titles and descriptions must cover every app-supported locale in the string catalog. Search aliases are not visible copy and should deliberately include both English and Simplified Chinese regardless of the active locale, for example:

- appearance: `appearance`, `theme`, `system`, `dark`, `light`, `外观`, `主题`, `跟随系统`, `深色`, `浅色`;
- launch: `launch at login`, `login item`, `startup`, `开机启动`, `登录项`, `自启动`;
- visibility: `show`, `hide`, `visible`, `dashboard`, `feature panel`, `显示`, `隐藏`, `可见`, `仪表盘`, `功能面板`.

Visibility keywords also include the localized plugin title, stable plugin ID, surface name, category, and release-channel metadata already used by search.

Add `AppHostCommands.swift` to the source list inspected by `PluginLocalizationCatalogAuditTests.testUnifiedSearchLocalizationKeysCoverAllSupportedLanguages`; otherwise new static keys in the new file would escape the current audit.

## File-by-File Changes

### New files

- `Sources/App/AppHostCommands.swift`
  - app/host command definition, action, context, catalog, applicability rules, stable IDs, and executor;
  - bilingual keyword aliases and surface-specific formatting;
  - execution continuation/result types.
- `Tests/App/AppHostCommandTests.swift`
  - catalog, applicability, stale-result validation, execution routing, failure behavior, and stable-ID coverage.

### Existing source files

- `Sources/App/AppAppearancePreference.swift`
  - add explicit `Hashable` conformance for use in typed command actions;
  - add the shared `storeAndApply(in:)` path while retaining `stored(in:)` and `applyStoredPreference(userDefaults:)`.
- `Sources/Core/Plugins/PluginHost.swift`
  - remove `AppShortcutAction.isCommandPaletteSearchEligible`;
  - retain global-shortcut registration behavior unchanged;
  - retain the current app presentation and plugin visibility APIs used by the executor.
- `Sources/App/MacToolsSearch.swift`
  - add `.appHostCommand(expectedDefinition:)` to `MacToolsSearchAction`;
  - remove the `AppShortcutAction.allCases` command scan;
  - accept applicable app/host definitions from the caller and map them to command results;
  - map plugin confirmations into `MacToolsCommandConfirmation`;
  - use the catalog's explicit shared-shortcut list for General Settings shortcut keywords.
- `Sources/App/UnifiedSearchPaletteView.swift`
  - inject the command context into `UnifiedSearchPaletteModel` and both palette presentations;
  - observe host, launch-at-login, and appearance changes;
  - execute `.appHostCommand` through the new executor;
  - dismiss only for `.dismissPalette`; refresh and resynchronize selection for state setters, stale results, and failures;
  - leave plugin command execution unchanged.
- `Sources/App/SettingsView.swift`
  - pass the shared appearance store and launch controller into the embedded palette;
  - initialize the appearance `@AppStorage` with that store;
  - use `storeAndApply(in:)` from the appearance picker.
- `Sources/App/AppWindowRouter.swift`
  - accept/store the appearance `UserDefaults` dependency;
  - pass the same command context to the standalone palette and Settings;
  - refresh launch-at-login status before presenting the standalone palette.
- `Sources/App/MacToolsApp.swift`
  - construct the router with the production appearance store explicitly and use it for initial appearance application.
- `Sources/Resources/Localization/Search.xcstrings`
  - add all command copy and formats for every supported locale.
- `Tests/App/MacToolsSearchTests.swift`
  - update action expectations;
  - verify supplied app/host definitions are indexed and searchable;
  - verify app shortcuts are not automatically promoted into commands;
  - verify confirmation metadata survives indexing.
- `Tests/Core/Plugins/PluginLocalizationCatalogAuditTests.swift`
  - include the new command source file in unified-search key discovery.

### User-facing documentation

- `README.md` and `README.zh-CN.md`
  - extend the Plugins & Settings description with appearance, launch-at-login, and per-surface plugin visibility commands.
- `changes/unreleased/command-palette-app-and-visibility-commands.md`
  - add one `release: app`, `type: added`, `area: Search` changelog fragment.

No `docs/plugins/` or `MacToolsPluginKit` change is needed because `PluginCommandProviding` remains unchanged and plugins receive visibility commands automatically from host state.

## Implementation Sequence

### Step 1: Add the command domain and shared appearance mutation

1. Add the app-local confirmation, definition, action, context, applicability, and execution-result types.
2. Declare the fixed command catalog and explicit shared-shortcut list.
3. Generate visibility definitions from the four existing host projections.
4. Add exact live-definition validation in the executor.
5. Add `AppAppearancePreference.storeAndApply(in:)` and switch Settings to it.
6. Run `make generate` so the new App and test source files are present in `MacTools.xcodeproj`.

Verification target: `AppHostCommandTests` covering pure catalog output before changing search UI.

### Step 2: Integrate the catalog with indexing

1. Change the index builder to accept applicable app/host definitions.
2. Remove automatic `AppShortcutAction.allCases` indexing.
3. Add the new search action and map definitions to results.
4. Preserve plugin command indexing, settings results, ranking, grouping, quick-selection numbering, and deduplication.

Verification target: `MacToolsSearchTests`.

### Step 3: Integrate execution and live refresh

1. Inject the shared context into embedded and standalone palettes.
2. Subscribe the model to all three applicability sources.
3. Route new command actions through the executor.
4. Keep state setters open and rebuild immediately; keep presentation and plugin command dismissal behavior unchanged.
5. Re-run selection synchronization after result IDs change so a disappearing command cannot leave an invalid selection.

Verification targets: model-level refresh tests and the relevant `AppWindowRouterTests` construction/presentation tests.

### Step 4: Localize and document

1. Add every supported-locale string and bilingual search aliases.
2. Extend localization audit discovery to the new file.
3. Update both READMEs and add the app changelog fragment.

Verification target: the unified-search localization audit method.

### Step 5: Manual end-to-end verification

Test both the Settings overlay palette and the standalone global-shortcut palette:

1. Search `appearance`, `外观`, `dark`, and `深色`; verify only non-current setters run, persist, apply immediately, and refresh the result set.
2. Change appearance in Settings, reopen Command-K, and verify the catalog reflects the same stored preference.
3. Search launch-at-login aliases; verify exactly one of Enable/Disable appears and the Settings switch tracks the same controller state.
4. Simulate or observe a launch-at-login registration failure; verify the palette stays open, the command remains applicable, and Settings retains the controller's localized error.
5. For a plugin supporting Dashboard, run Hide and verify the Dashboard layout row moves to hidden while the command becomes Show; repeat for Feature Panel.
6. For a plugin supporting both surfaces, verify changing one surface does not affect the other.
7. Install/uninstall or reload a dynamic plugin while Command-K is open; verify stale visibility results refresh or safely refuse execution.
8. Verify Toggle Dashboard, Toggle Feature Panel, Lock Screen, Display Sleep, and other existing plugin commands behave as before.
9. Verify a synthetic confirmed app/host command follows the existing alert path and does not execute when Cancel is chosen.

## Focused Test Matrix

### Catalog and applicability

- Fixed command IDs are unique, stable, and have non-empty localized metadata.
- A System/Dark/Light state table proves the current appearance setter is omitted and the other two are present.
- Launch-at-login produces exactly Enable when disabled and Disable when enabled.
- Visible and hidden surface arrays produce the correct inverse command.
- A dual-surface plugin produces one applicable command per surface.
- Unsupported surfaces and incompatible/unloaded packages produce no visibility command.
- English and Chinese aliases find the same command under any active app locale.

### Execution and safety

- Appearance execution writes only the injected temporary defaults suite, posts the existing appearance-change notification, and returns `.refreshIndex`.
- Launch execution calls the injected fake service through `LaunchAtLoginController`; successful and failed registrations are distinguished by resulting controller state.
- Visibility execution changes only the requested surface and preserves its remembered order.
- A stale appearance, launch, visibility, removed-plugin, or relocalized definition returns `.unavailable` without mutation.
- Dashboard/Feature Panel presentation uses the existing app presentation handler and returns `.dismissPalette`.
- A definition with confirmation reaches the shared confirmation path before executor invocation.

### Index and refresh

- App/host definitions appear as `.command` results with stable IDs, metadata, keywords, image, confirmation, and expected definition in the action.
- `AppShortcutAction` additions do not appear unless explicitly declared by the catalog.
- Rebuilding after appearance, launch, and visibility changes removes the old no-op result and exposes the newly applicable result.
- Plugin-owned commands are still gathered exclusively from `PluginCommandProviding`.
- Navigation and setting results remain available beside related command results.

## Verification Commands

Run the smallest relevant tests first:

```bash
make generate
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/AppHostCommandTests
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/MacToolsSearchTests
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/AppWindowRouterTests
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet -only-testing:MacToolsTests/PluginLocalizationCatalogAuditTests/testUnifiedSearchLocalizationKeysCoverAllSupportedLanguages
```

Then run `make build` because this change crosses App, Core-owned host APIs, localization resources, and both command-palette presentation paths. A full test suite is appropriate before merging if the focused tests and build pass.

## Acceptance Criteria Mapping

- Explicit appearance commands: fixed catalog definitions plus state-table tests.
- Persisted and applied appearance: shared `storeAndApply(in:)` path used by Settings and executor.
- Applicable launch command only: live controller-based catalog filtering.
- Shared launch state: executor uses the existing `LaunchAtLoginController`.
- Automatic per-surface plugin commands: generated from host surface projections.
- Shared visibility state: executor uses `PluginHost.setPluginVisible`.
- Immediate refresh: `.refreshIndex` execution continuation and model subscriptions.
- No plugin changes: host projections generate commands without new protocol requirements.
- Plugin commands remain opt-in: unchanged `PluginCommandProviding` collection/execution.
- Complex/destructive settings excluded: catalog is explicit; no settings-to-command inference and no uninstall command.
- Focused tests: catalog, stale validation, controller execution, index refresh, and confirmation propagation suites above.

## Risks and Guardrails

- **Stale result execution:** always compare the full expected definition against the newly derived applicable definition before mutation.
- **Launch-at-login failure:** trust the controller's post-operation state, not the requested Boolean; preserve `lastErrorMessage` for Settings.
- **Appearance test leakage:** inject a temporary `UserDefaults` suite and restore `NSApp.appearance`/notification observers in teardown.
- **Cross-surface visibility mistakes:** derive and execute with an explicit `PluginDisplaySurface`; test surface independence.
- **Publisher timing:** keep the existing yielded/coalesced rebuild rather than rebuilding synchronously from `objectWillChange` before values update.
- **Selection after a result disappears:** resynchronize by result ID after every refresh and fall back to the first remaining result.
- **Localization gaps:** add the new source file to audit discovery and require all supported locales in `Search.xcstrings`.
- **Plugin compatibility:** do not modify `PluginCommandProviding`, `PluginCommandDefinition`, or the PluginKit version.

## Non-Goals

- Converting every setting, panel button, or shortcut into a command.
- Adding inline controls to search results.
- Adding commands for permission prompts, path selection, shortcut recording, preference import/export, plugin install/update/uninstall, or other multi-step workflows.
- Adding a plugin enabled/disabled lifecycle.
- Adding new global-shortcut actions for appearance, launch-at-login, or visibility.
- Expanding plugin-specific commands beyond the existing providers in this issue.
