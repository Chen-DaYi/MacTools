# MacTools URL Scheme

MacTools exposes a small navigation-only URL API for shortcuts, launchers, scripts, and links from other apps.

- Release app: `mactools://`
- Debug app: `mactools-dev://`

## Public routes

| Destination | Release URL |
| --- | --- |
| Settings | `mactools://app/settings` |
| General settings | `mactools://app/settings/general` |
| About | `mactools://app/settings/about` |
| Plugin Marketplace | `mactools://app/settings/plugins/marketplace` |
| Installed plugin settings | `mactools://app/settings/plugins/<plugin-id>` |
| Dashboard | `mactools://app/panels/dashboard` |
| Feature Panel | `mactools://app/panels/feature` |
| Unified search | `mactools://app/search` |

For example:

```bash
open 'mactools://app/settings/plugins/fan-control'
open 'mactools://app/panels/dashboard'
open 'mactools://app/search'
```

Use the stable ID from the plugin's `plugin.json` for `<plugin-id>`. The ID `marketplace` is reserved for the host-owned Marketplace route and cannot be used by a plugin. A plugin settings link is accepted only when that plugin is installed, loaded, and provides settings. Dashboard and Feature Panel links always use show/focus behavior, so opening the same link again does not toggle the panel closed.

## Compatibility

Published routes are a backward-compatible product interface and are independent of the MacTools app version. New routes and optional parameters may be added, but an existing route will keep its meaning. Unique unknown query parameters are ignored; duplicate parameter names and malformed or unavailable destinations are rejected.

The URL namespace has no global version. If a future feature needs an incompatible structured payload, that feature will use a dedicated `formatVersion` or `protocolVersion` parameter.

## Security

Any local process or website can invoke a custom URL scheme, so the public API is intentionally navigation-only. It does not expose plugin controls, settings action IDs, shortcut IDs, raw panel actions, shell text, arbitrary app paths, or filesystem/system mutations. Command-shaped paths such as `/app/plugins/<plugin-id>/commands/<command-id>` are not supported.

Do not put secrets in URL parameters. Rejected links produce a diagnostic reason, but MacTools does not log complete public URLs or query values.

## Finder Sync compatibility

The existing `mactools://right-click/...` namespace is reserved for the bundled Finder Sync extension and remains backward-compatible. It is separate from the public `app` namespace; individual plugins must not register their own URL schemes.
