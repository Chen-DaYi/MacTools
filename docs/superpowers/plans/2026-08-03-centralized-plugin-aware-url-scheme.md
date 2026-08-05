# Centralized Plugin-Aware URL Scheme Implementation Plan

> Source: GitHub issue #234. This plan is frozen for implementation on 2026-08-03 and intentionally starts with navigation-only public routes.

## Goal

Turn the existing `mactools://` / `mactools-dev://` registration into a centralized, typed deep-link API while preserving every published Finder Sync URL. The host app owns the public namespace, resolves plugin settings from stable plugin IDs, waits for dynamic plugin loading during cold launch, and uses deterministic presentation requests.

## Public contract

Release builds accept `mactools://`; Debug builds accept `mactools-dev://`. The first public route set is:

| Route | Typed destination | Presentation behavior |
| --- | --- | --- |
| `app/settings` | settings root | Show the Settings window without changing an already selected page |
| `app/settings/general` | General | Show Settings and select General |
| `app/settings/about` | About | Show Settings and select About |
| `app/settings/plugins/marketplace` | Marketplace | Show Settings and select Marketplace |
| `app/settings/plugins/<plugin-id>` | Installed plugin configuration | Resolve the exact stable plugin ID after plugin loading, then show its configuration; `marketplace` is reserved by the host route above |
| `app/panels/dashboard` | Dashboard | Show or focus Dashboard; never toggle it closed |
| `app/panels/feature` | Feature Panel | Show or focus Feature Panel; never toggle it closed |
| `app/search` | Unified search | Show Settings and present/focus unified search |

Unique, unknown query parameters are ignored so compatible metadata can be added later. Duplicate query names, fragments, authority credentials, ports, malformed plugin IDs, unknown paths, and URLs larger than 4 KiB are rejected. Trailing slashes are tolerated. Startup queues at most 32 valid public links.

The existing `right-click` host remains a separate compatibility namespace and is delegated unchanged to `RightClickURLRouter`. Its existing filesystem actions and input behavior are not reinterpreted by the public parser.

## Security and compatibility boundaries

- Public routes are navigation-only. `/app/plugins/<plugin-id>/commands/<command-id>` and every other command-shaped route are rejected.
- Plugins receive no URL, query item, control ID, settings action ID, shortcut ID, or raw `PluginPanelAction`.
- A plugin settings link succeeds only when `PluginHost` exposes a configuration item for that exact ID after dynamic plugin initialization.
- The router logs a bounded diagnostic reason and route shape, never the complete URL or query values.
- The namespace is unversioned. Published route meaning is stable and future evolution is additive. Any future incompatible payload must version only that feature boundary.

## Architecture

### 1. Pure parsing and typed routes

Add `Sources/App/AppURLRouter.swift` with:

- `AppDeepLink`, including typed settings and panel destinations.
- `AppDeepLinkParser`, a pure `URLComponents` parser with explicit limits and errors.
- `AppURLRouter`, the `@MainActor` delivery coordinator.

The central router validates the registered scheme and dispatches by host. `right-click` is delegated immediately. Valid `app` links are parsed into `AppDeepLink` before they are queued or delivered.

### 2. Presentation mapping

Extend the existing request enums rather than adding a second window API:

- `SettingsPresentationRequest`: add explicit General and About requests.
- `AppPresentationRequest`: add deterministic Dashboard, Feature Panel, and unified-search requests alongside the existing shortcut toggle requests.
- `AppWindowRouter`: map explicit settings requests onto `SettingsNavigationCoordinator`.
- `MenuBarStatusItemController`: map deterministic panel requests to `showDashboard()` / `showFeaturePanel()` and search to `AppWindowRouter.showUnifiedSearch()`.

This keeps deep links independent of click-swap preferences and ensures repeated URL delivery focuses the requested surface instead of closing it.

### 3. Cold-launch lifecycle

`MacToolsAppDelegate` owns one `AppURLRouter` from delegate construction onward. URLs delivered before `applicationDidFinishLaunching` are parsed and queued. Finder Sync links continue to delegate immediately.

The router becomes active only after:

1. `AppWindowRouter` and `MenuBarStatusItemController` install the app presentation handler; and
2. `PluginHost.loadDynamicPluginsIfNeeded()` finishes, including the automatic-update-before-load path.

Activation drains queued links in arrival order. Plugin availability is checked at delivery time, after dynamic plugins are ready.

### 4. Diagnostics

Add an `AppURLRouter` category to `AppLog`. Rejections distinguish unsupported schemes/hosts/routes, malformed IDs/components, duplicate parameters, oversized input, unavailable plugins, and queue overflow without logging query values.

## File changes

- Add `Sources/App/AppURLRouter.swift`.
- Modify `Sources/App/MacToolsApp.swift` for central ownership, delegation, activation, and cold-launch draining.
- Modify `Sources/Core/Plugins/PluginHost.swift` to extend typed presentation requests.
- Modify `Sources/App/AppWindowRouter.swift` for explicit General/About requests.
- Modify `Sources/App/MenuBarStatusItemController.swift` for deterministic panel/search request mapping.
- Modify `Sources/Core/Diagnostics/AppLog.swift` for URL diagnostics.
- Add `Tests/App/AppURLRouterTests.swift`.
- Update adjacent App window and menu-bar presentation tests.
- Add `docs/url-scheme.md`, link it from `README.md`, and add an app changelog fragment.

No `project.yml` source-list change is required because the app target includes `Sources/` and `Tests/` recursively.

## Test plan

### Parser tests

- Accept every documented route for injected Release and Debug schemes.
- Decode and validate exact plugin IDs.
- Ignore unique optional parameters and reject duplicate names.
- Reject wrong schemes, wrong hosts, unknown paths, malformed plugin IDs, fragments/credentials/ports, command routes, and oversized inputs.

### Router tests

- Delegate existing Release and Debug `right-click` URLs immediately, including before activation.
- Queue public routes before activation and drain them in order afterward.
- Reject queue overflow without displacing earlier links.
- Reject unavailable plugin settings after activation.
- Map repeated panel links to deterministic `show` requests.

### Presentation and lifecycle tests

- Verify explicit General/About requests select the correct settings destination.
- Verify deterministic Dashboard/Feature Panel requests are distinct from shortcut toggles and ignore swapped click preferences.
- Verify unified search routes through the existing search presentation API.
- Use the queue-drain test as the isolated cold-launch lifecycle test; the app delegate only wires the tested coordinator to existing dependencies.

### Required verification

1. `make generate`
2. Focused XCTest classes: `AppURLRouterTests`, `AppWindowRouterTests`, `MenuBarStatusItemControllerTests`, and `RightClickURLSchemeTests`
3. Full `MacTools` XCTest suite
4. `python3 scripts/changelog.py validate --release app`

All Xcode checks run with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. Generated Xcode files, `Configs/GeneratedPlugins.yml`, and `build/` are ephemeral verification outputs.

## Non-goals

- External plugin commands or typed plugin payload protocols
- Destructive-action confirmations (there are no public mutation routes in this release)
- Universal Links, authentication, or extension-to-host IPC
- A namespace-wide version number
- Changes to Finder Sync action parsing, validation, or execution

## Rollback and forward compatibility

The new host is additive within the already registered scheme, so rollback consists of removing `app` routing while leaving `right-click` untouched. Once released, documented paths must continue to resolve to the same typed destinations. Future routes should add enum cases and parser branches; incompatible payloads must introduce a feature-local `formatVersion` or `protocolVersion` only when needed.
