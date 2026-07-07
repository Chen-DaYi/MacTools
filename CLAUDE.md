# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Claude Code Adapter
- Canonical shared rules — build/test commands, plugin conventions, the settings-UI spec, Swift style, feature safety boundaries, test requirements, agent workflow — live in `AGENTS.md` (imported above). Read it; update it rather than duplicating rules here.
- `GEMINI.md` is a parallel thin adapter to the same `AGENTS.md`. Put personal/machine-local Claude notes in `CLAUDE.local.md` (do not commit).

## Runtime Architecture Overview

MacTools has a menu-bar host plus plugins architecture. Three areas must be understood together: the host (`Sources/App` + `Sources/Core/Plugins`), the plugin protocol layer (`Sources/MacToolsPluginKit`), and feature plugins (`Plugins/<Name>`).

**Two plugin types and two loading paths**
- *Static plugins*: `Plugins/<Name>/` lives in the tree and is compiled into the app by XcodeGen. `scripts/plugins/generate-plugin-project-config.rb` scans each `plugin.json`, writes the local uncommitted `Configs/GeneratedPlugins.yml`, and feeds `project.yml` into `MacTools.xcodeproj`. Ordinary new plugins should not require root `project.yml` edits.
- *Dynamic plugins*: `.mactoolsplugin` packages are handled at runtime by the `Sources/Core/Plugins/Dynamic` stack: `PluginPackageStore` installs and records packages and provides each plugin's `runtimeContext` with support/cache/temp directories plus pluginID-scoped storage; `PluginTrustValidator` validates trust and fails closed; `DynamicPluginManager`/`DynamicPluginLoader` load packages, support `pausePlugin`/`resumePlugin`, and mark hot updates for restart. `plugin.json.id` must equal the runtime `PluginMetadata.id`.

**The host is the hub (`PluginHost`), and plugins never touch menu-bar UI directly.** The host derives renderable items from each plugin's `primaryPanelState`, `componentPanelState`, `settingsSections`, `permissionRequirements`, and `shortcutDefinitions`. It owns ordering, visibility, shortcuts, permission cards, component-view caching, and coalesced/debounced state rebuilds. The four user-visible surfaces are the menu-bar feature panel (`PluginPrimaryPanel`), component dashboard (`PluginComponentPanel`), general settings, and plugin-management page.

**UI is declarative, not raw SwiftUI.** Use `PluginPanelState`, `PluginPanelDetail`, `PluginPanelControl`, and `PluginConfiguration` to describe UI for host rendering. Write real SwiftUI only in `PluginComponentPanel.makeView` and `PluginConfiguration.makeView`, for cases such as complex lists, drag and drop, or charts.

**Data flow**: user action -> `handleAction(PluginPanelAction)` -> plugin mutates its own state -> plugin calls `onStateChange?()` -> host rebuilds derived state and re-renders. **External system events** such as display hot-plugging, permission changes, filesystem changes, or calendar authorization must not depend on "refresh when the user expands a panel." They need explicit observers, such as Core-layer `DisplayConfigurationObserving` notifications feeding plugins that implement `DisplayTopologyRefreshing`, with debounce where appropriate.

**Lifecycle**: `activate(context:)` / `deactivate(reason:)`. `reason.requiresStateCleanup` distinguishes real cleanup paths such as disable, uninstall, or shutdown, where system side effects must be reverted, from `.updating` hot-update paths, where cleanup is intentionally skipped and a process restart completes unload. When touching side-effect code, do not silently swallow cleanup failures. Forced discharge, brightness overrides, wallpaper changes, event taps, and similar effects must have restoration and user-exitable paths.

## Build Pitfalls
- `MacTools.xcodeproj`, `Configs/GeneratedPlugins.yml`, and `Configs/LocalConfig.xcconfig` are generated and gitignored. **After switching git branches, run `make generate` again.** The `.xcodeproj` references concrete files, so branch changes, added sources, or deleted sources can otherwise cause build failures or missing files.
- The platform is **macOS**, not the iOS simulator. For a quick single-plugin compile, use `-scheme <Name>Plugin -destination 'platform=macOS'`. For one test class, append `-only-testing:MacToolsTests/<TestClassName>` to the full test command from `AGENTS.md`.
- Plugin tests live under `Plugins/<Name>/Tests/`, but they run inside the `MacToolsTests` bundle. Typical imports are `@testable import MacTools` plus `@testable import <Name>Plugin`.
