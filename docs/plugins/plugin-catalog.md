# MacTools Plugin Catalog

MacTools dynamic plugins use one catalog-driven flow for both production distribution and local development.

- Production reads `catalog.json` from GitHub Pages and downloads plugin packages from GitHub Releases.
- Local development reads a Debug-only `file://` catalog, usually configured with `MACTOOLS_PLUGIN_CATALOG_URL`.
- Both flows resolve catalog entries into local staged packages, verify checksum and manifest compatibility, then install through the same package store. The marketplace can update one plugin at a time or run a batch update for every currently updateable plugin.

## Catalog v1

```json
{
  "schemaVersion": 1,
  "catalogID": "com.ggbond.mactools.plugins",
  "generatedAt": "2026-05-16T12:00:00Z",
  "minimumHostVersion": "0.15.2",
  "pluginKitVersion": 2,
  "plugins": [
    {
      "id": "com.ggbond.mactools.demo",
      "displayName": "Demo",
      "summary": "示例插件",
      "localizedMetadata": {
        "zh-Hans": {
          "displayName": "示例",
          "summary": "示例插件"
        },
        "en": {
          "displayName": "Demo",
          "summary": "Demo plugin"
        }
      },
      "version": "1.0.0",
      "minimumHostVersion": "0.15.2",
      "pluginKitVersion": 2,
      "capabilities": {
        "primaryPanel": true,
        "componentPanel": false,
        "configuration": true
      },
      "permissions": [],
      "package": {
        "url": "https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1/Demo.mactoolsplugin.zip",
        "sha256": "...",
        "size": 1234567
      },
      "releaseNotesURL": "https://github.com/ggbond268/MacTools/releases/tag/plugins-1.0.1",
      "category": "productivity",
      "releaseChannel": "beta"
    }
  ],
  "revoked": [],
  "signature": {
    "algorithm": "ed25519",
    "value": "..."
  }
}
```

`localizedMetadata` is copied from each plugin manifest and is used by the marketplace before the plugin bundle is loaded. `displayName` and `summary` remain required fallbacks for older hosts and incomplete translations.

Release catalogs must include an Ed25519 signature. Debug local catalogs may omit `signature`, but they still go through package checksum, manifest, staging, and same-team code signature validation.

## Local Development

The default local workflow is convention based:

```text
MacTools/
  Plugins/
    Demo/
      plugin.json
      Sources/
      Bundle/
      Tests/
```

External plugin repositories can use the same structure, as long as the manifest can resolve either a buildable project or a prebuilt bundle:

```text
MacToolsPlugins/
  Demo/
    plugin.json
    Sources/
    Bundle/
    Tests/
```

`plugin.json` declares the plugin ID, version, capabilities, bundle path, optional `releaseChannel`, and build scheme. In this repository `make generate`, `make build`, `make run`, and `make build-plugin` first scan `Plugins/*/plugin.json` and generate the local XcodeGen plugin targets. External repositories may provide their own `project.yml`, `.xcodeproj`, or the declared bundle directory. The built package contains only `plugin.json` and the signed `.bundle`; extra executables must already be copied into the bundle resources and listed in `plugin.json.package.signPaths` when they require an individual code signature.

From the MacTools repository, build all local plugins and generate the Debug catalog:

```bash
make build-plugin
```

Or build one plugin by directory name or plugin ID:

```bash
make build-plugin PLUGIN=Demo
make build-plugin PLUGIN=com.example.mactools.demo
```

Generated output lives under:

```text
build/LocalPlugins/
  Packages/*.mactoolsplugin
  catalog.dev.json
```

Then run MacTools:

```bash
make run
```

`make run` starts the app executable directly so the catalog environment variable reaches the app process. If `MACTOOLS_PLUGIN_CATALOG_URL` is not already set and `build/LocalPlugins/catalog.dev.json` exists, Make uses that file automatically.

You can override the fixed directories:

```bash
make build-plugin LOCAL_PLUGIN_SOURCE_DIR=/path/to/plugins LOCAL_PLUGIN_BUILD_DIR=/path/to/build
make run MACTOOLS_PLUGIN_CATALOG_URL=file:///path/to/catalog.dev.json
```

For Debug runs, the catalog URL scheme selects the verification mode. A `file://` URL uses the local development catalog policy, where signatures are optional. An `https://` URL uses the production catalog policy, where the catalog signature is required:

```bash
make run MACTOOLS_PLUGIN_CATALOG_URL=https://mactools.ggbond.app/plugins/catalog.json
```

The app copies the package into its own staging and installed directories. Uninstall deletes only the installed copy under MacTools application support; it never deletes the plugin source directory or the local build directory.

## Release Flow

Recommended production flow is an incremental batch plugin release:

1. Run `make release`.
2. Choose `plugin`, release mode, and `patch`/`minor`/`major`.
3. The helper analyzes the production catalog and shows the planned manifest bumps.
4. After confirmation, the helper syncs `main`, bumps changed plugin manifests when needed, compiles `release: plugin` changelog fragments into `CHANGELOG.md`, runs a release plan check, commits the bump, and pushes a batch tag such as `plugins-1.0.1`.
5. The `Plugin Release` GitHub Action reads the current production catalog from `origin/main`.
6. In default `auto` mode, the workflow selects only new plugins and plugins whose manifest version is higher than the previous catalog entry.
7. If package-relevant files changed inside a plugin or its `pluginKitVersion` changed but that plugin version did not increase, the workflow fails before signing or uploading. PluginKit ABI changes require a full `mode=all` rebuild; other shared host changes can use `mode=all` or explicit `--shared-path` values when they really require repackaging existing plugins.
8. The workflow builds, signs, zips, and uploads only the selected plugin packages.
9. The workflow generates a delta catalog for the selected packages, merges those entries into the previous production catalog, and keeps unchanged plugin entries pointing at their existing assets.
10. The merged catalog is signed and committed back to `docs/plugins/catalog.json`.
11. `Deploy Pages` publishes the signed catalog to GitHub Pages.

The batch tag is stored per plugin entry through `package.url` and `releaseNotesURL`, so one catalog can point different plugins to different release tags without changing host code.

The GitHub Release body for each plugin batch is extracted from the matching `CHANGELOG.md` entry, such as `## [plugins-1.0.1]`.

An incremental release record contains only packages changed in that batch:

```text
GitHub Release: plugins-1.0.1
  calendar.mactoolsplugin.zip
  display-brightness.mactoolsplugin.zip
```

Unchanged plugin entries remain valid because the catalog preserves their previous URLs, checksums, and versions. They are not shown as updates in the app unless their catalog version is higher than the installed version.

`pluginKitVersion` is the PluginKit ABI boundary. When it changes, every plugin package must be rebuilt and each plugin's manifest version must increase so installed users see an update. The catalog merge step rejects mixed PluginKit versions.

When a full rebuild is needed, run the `Plugin Release` workflow manually with `mode=all`. To publish a controlled subset, use `mode=selected` and pass comma-separated plugin IDs or directory names in `plugins`.

Each zip keeps the package root:

```text
appearance.mactoolsplugin/
  plugin.json
  Appearance.bundle/
    Contents/
      Info.plist
      MacOS/Appearance
      Resources/
      _CodeSignature/
```

Local dry-run packaging uses the same release asset script:

```bash
make package-plugins-release \
  PLUGIN_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  PLUGIN_CATALOG_PRIVATE_KEY_BASE64="$PLUGIN_CATALOG_PRIVATE_KEY_BASE64" \
  PLUGIN_RELEASE_TAG=plugins-1.0.1
```

Generated local output:

```text
build/PluginRelease/
  Assets/*.mactoolsplugin.zip
  catalog.json
docs/plugins/catalog.json
```

The lower-level scripts are still useful for external plugin repositories. `build-plugin-release-assets.sh` can build all plugins or a subset with repeated `--plugin` arguments:

```bash
scripts/plugins/plan-plugin-release.py \
  --mode auto \
  --previous-catalog docs/plugins/catalog.json \
  --output build/PluginRelease/plan.json

scripts/plugins/build-plugin-release-assets.sh \
  --base-url https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1 \
  --catalog-output build/PluginRelease/catalog.delta.json \
  --sign-identity "Developer ID Application: Example (TEAMID)" \
  --plugin calendar \
  --plugin display-brightness

scripts/plugins/merge-plugin-catalog.py \
  --previous docs/plugins/catalog.json \
  --updates build/PluginRelease/catalog.delta.json \
  --plan build/PluginRelease/plan.json \
  --plugin-kit-version 2 \
  --output build/PluginRelease/catalog.merged.json

scripts/plugins/generate-plugin-catalog.sh \
  --mode release \
  --base-url https://github.com/ggbond268/MacTools/releases/download/plugins-1.0.1 \
  --output dist/catalog.json \
  --package dist/Demo.mactoolsplugin.zip \
  --release-notes-url https://github.com/ggbond268/MacTools/releases/tag/plugins-1.0.1

scripts/plugins/sign-plugin-catalog.sh \
  --input build/PluginRelease/catalog.merged.json \
  --output docs/plugins/catalog.json \
  --private-key-base64 "$PLUGIN_CATALOG_PRIVATE_KEY_BASE64"
```

The catalog private key, Developer ID identity, and GitHub token must come from local environment variables or CI secrets. Do not commit them. The catalog public key is safe to embed in the app as `PLUGIN_CATALOG_PUBLIC_KEY`.

## Runtime Lifecycle

Install, update, enable, disable, and uninstall are immediate at the UI contribution level:

- Installed and enabled plugins contribute panels, components, settings, permissions, and shortcuts.
- Disabled plugins are removed from UI and function lists immediately.
- Uninstalled plugins are removed from UI immediately and package files are deleted.
- Batch updates resolve the currently updateable catalog entries and rebuild plugin management state once after successful package replacements.
- Already-loaded native code is not force-unloaded in-process. The executable code is fully released after the app restarts.

This keeps the native bundle lifecycle aligned with macOS loadable bundle constraints while preserving a predictable management UI.
