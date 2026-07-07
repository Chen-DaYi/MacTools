# Contributing to MacTools

<a href="CONTRIBUTING.zh-CN.md">[中文]</a> [English]

Thanks for your interest in MacTools. Please keep each contribution small and clear: explain the problem, provide verifiable changes, and avoid mixing unrelated refactors into the same pull request.

## Ways to Contribute
- Bug reports should include reproduction steps, expected behavior, actual behavior, macOS version, and relevant logs or screenshots.
- Feature suggestions should describe the use case, target users, and expected interaction. For large plugins or interaction changes, open an issue first to align on scope.
- Changes involving file deletion, system permissions, global shortcuts, display control, signing, or update flows should explain risks, safeguards, and rollback options.

## Development Environment
- Xcode and `xcodegen` are required. The project supports macOS 14.0 and later.
- First-time setup: run `make setup`, then edit `LocalConfig.xcconfig` and fill in `DEVELOPMENT_TEAM` and `BUNDLE_IDENTIFIER_PREFIX`.
- Common commands: `make generate` generates the Xcode project, `make build` validates compilation, and `make run` runs the app locally.
- Plugin development: `make run` incrementally builds the app and plugins, then syncs the latest Debug plugin packages to the local development marketplace. `make sync-debug-plugins` only syncs already built plugins. `make build-plugin` is reserved for validating dynamic plugin packages or release flows; to build one plugin, run `make build-plugin PLUGIN=calendar`.
- Do not commit local or generated files: `MacTools.xcodeproj`, `MacTools.xcworkspace`, `LocalConfig.xcconfig`, `build/`, or `scripts/release.local.env`.

## Project Structure
- `Sources/App/`: app entry point, menu bar status item, settings pages, and window routing.
- `Sources/Core/`: shared infrastructure such as the plugin host, dynamic plugin loading, shortcuts, permissions, logging, and updates.
- `Sources/MacToolsPluginKit/`: plugin APIs, declarative UI models, and runtime context.
- `Plugins/<PluginName>/`: plugin manifest, source code, bundle entry point, resources, and adjacent tests.
- `Tests/`: XCTest coverage for shared App/Core logic. Plugin tests should live inside the corresponding plugin directory when possible.
- `project.yml`: root XcodeGen project source, only for the App, PluginKit, and shared aggregate entry points. Plugin targets are generated automatically.
- `Plugins/<PluginName>/project.yml`: optional per-plugin build overrides, only when a plugin needs extra frameworks, include paths, bundle resources, helper/tool targets, or target overrides.
- `docs/plugins/`: plugin packages, catalogs, local debugging, and release flow documentation.
- `docs/superpowers/`: larger product, interaction, or implementation design documents.

## Development Guidelines
- Add new plugins under `Plugins/<PluginName>/` with at least `plugin.json`, `Sources/`, and `Bundle/`.
- Ordinary plugins only need to define `plugin.json`, source code, and a bundle entry point. `make generate` scans `Plugins/*/plugin.json` and generates local `Configs/GeneratedPlugins.yml`; do not edit generated files manually.
- Features that require macOS app extensions, such as Finder Sync, must add the extension target to the root `project.yml` and embed it in the main app. Use the dynamic plugin only for the MacTools panel/settings surface.
- Command workflows for adding and updating plugins are documented in the Development Steps section of `docs/plugins/local-native-plugins.md`.
- Keep documentation short and task-focused. User-visible behavior changes should update `README.md` or the relevant file under `docs/`; plugin package, catalog, or release flow changes should update `docs/plugins/`.
- Plugins implement `MacToolsPlugin`; menu panel plugins implement `PluginPrimaryPanel`, and component panel plugins implement `PluginComponentPanel`.
- `plugin.json.id` must be stable, readable, and exactly match the runtime `PluginMetadata.id`; each plugin package should return exactly one plugin instance.
- Plugin display state should be expressed through `PluginPanelState`, `PluginPanelDetail`, `PluginPanelControl`, and related models. Do not bypass the existing panel framework.
- Prefer declarative plugin settings through `settingsSections`, `permissionRequirements`, `shortcutDefinitions`, and related models. Use a custom `PluginConfiguration` view only for complex managers or specialized interactions.
- If ordinary plugin resources rarely change, prefer bundling them into the executable. If extra bundle resources are needed, declare the smallest necessary differences in the plugin's own `project.yml`.
- Custom plugin settings views must reuse `MacToolsPluginKit.PluginSettingsTheme` and `.pluginSettingsCardBackground(...)`. Do not copy private plugin settings styles, and do not make plugins depend on `Sources/App/SettingsStyle.swift`.
- Call `onStateChange?()` after plugin state changes. Long-running scans, file system work, and system calls should not block the main thread for extended periods.
- User-facing copy is primarily Chinese. Keep it concise, clear, and close to native macOS wording.
- Localize user-facing copy with `.xcstrings`. App/Core copy belongs under `Sources/Resources/Localization`, PluginKit copy under `Sources/MacToolsPluginKit/Resources`, and plugin copy under `Plugins/<PluginName>/Resources`. Plugin `plugin.json` files should keep `displayName`/`summary` as fallbacks and add `localizedMetadata` for marketplace and unloaded-plugin presentation.
- New plugins should provide localization whenever practical, at minimum for panel copy, settings copy, permission text, and plugin metadata.
- Prefer Apple native frameworks. When adding system frameworks, private include paths, or helper executables inside a plugin bundle, declare the smallest necessary differences in the plugin's own `project.yml`. Bundle resource executables that need separate signing should be listed in `plugin.json.package.signPaths`.

## Testing
- Behavioral changes should add or update adjacent XCTest coverage. Test files should be named `<TypeName>Tests.swift`.
- Full test command: `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`.
- Single test class: append `-only-testing:MacToolsTests/<TestClassName>` to the full test command.
- File system tests should use temporary directories or fake stores. Disk cleanup tests must not delete real user directories.

## Pull Request Checklist
- Keep the PR focused, and explain the purpose, verification, and user impact.
- Prefer English for commit messages, pull request titles/descriptions, and issues.
- Build or tests have passed. If they could not be run, explain why in the PR.
- User-visible behavior changes are reflected in `README.md` or the relevant design documentation.
- User-visible app or plugin changes include a concise English changelog fragment in `changes/unreleased/*.md`.
- High-risk features cover safety checks, error states, and missing-permission cases.
- The PR does not include unrelated formatting, generated files, local configuration, certificates, or release credentials.

## Release
- Releases are handled by maintainers. Do not create tags, publish GitHub Releases, or commit release artifacts in ordinary contributions.
- For GitHub-based releases, prefer `Actions` -> `Prepare Release`. Enter `type`, target `version`, and whether to `release`; when `release` is enabled, the workflow continues to the actual release workflow after bumping, committing, and creating the tag.
- For quick releases, prefer `make release`. The command interactively chooses `app` or `plugin`, analyzes the next `patch`/`minor`/`major` version, previews the bump, then only after confirmation runs `git pull --rebase`, lightweight checks, version updates, commit, tag creation, and tag push.
- App releases update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Configs/AppVersion.xcconfig`. The app and embedded extensions inherit this shared version config. After pushing a `v*.*.*` tag, the `Release` workflow builds, signs, notarizes, and uploads the DMG.
- Plugin releases push a `plugins-*` batch tag. The default `auto` mode uses the production catalog to find new plugins, already bumped plugins, and package-related plugin changes; it updates `plugin.json.version` when needed, then the `Plugin Release` workflow builds plugins and merges the signed catalog.
- On first launch, a new app version checks installed plugins and automatically updates them from the signed production catalog. It does not automatically install plugins the user has not installed.
- Non-interactive examples: `make release ARGS="--type app --version 1.0.7 --yes"` or `make release ARGS="--type plugin --version 1.0.10 --plugin-mode selected --plugin calendar --yes"`.
- Add `--dry-run` to preview the steps. The working tree must be clean before a real release.
- Before local release builds, copy `scripts/release.local.env.sample` to `scripts/release.local.env` and fill in at least `DEVELOPER_ID_APPLICATION`.
- If Apple notarization is needed, store credentials first with `xcrun notarytool store-credentials`.
- Version numbers default to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Configs/AppVersion.xcconfig`.
- Local production builds can still use the lower-level script: `./scripts/release-local.sh`; before publishing to GitHub Releases, run `gh auth login`, then `./scripts/release-local.sh --publish`.
- Plugin library releases are triggered by `plugins-*` batch tags through the `Plugin Release` workflow. By default, only plugins with bumped versions are built and uploaded, then merged into the production catalog. The catalog private key, Developer ID certificate, and GitHub token must come from CI secrets or local environment variables.
- GitHub Actions build and release configuration is documented in `docs/github-actions.md`; plugin catalog, package structure, and batch release flows are documented in `docs/plugins/plugin-catalog.md`.
