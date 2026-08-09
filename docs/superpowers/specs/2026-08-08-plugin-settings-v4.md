# Plugin Settings v4

## Decision

MacTools owns the settings experience; plugins contribute settings data and bounded custom content. PluginKit 4 deliberately removes the v3 configuration API instead of carrying a compatibility renderer.

This follows the same separation used by macOS Settings/SwiftUI `Form`, VS Code configuration contributions, and Raycast preferences: standard preferences are described by extensions and rendered by the host. Like IntelliJ tool windows, task-oriented managers remain possible, but they use a distinct workspace surface rather than pretending every screen is a form.

Primary references:

- [Apple Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [SwiftUI Form](https://developer.apple.com/documentation/swiftui/form)
- [VS Code configuration contribution](https://code.visualstudio.com/api/references/contribution-points#contributesconfiguration)
- [Raycast preferences](https://developers.raycast.com/api-reference/preferences)
- [IntelliJ Settings Guide](https://plugins.jetbrains.com/docs/intellij/settings-guide.html)

## Ownership

The host owns navigation, the page header, semantic background colors, grouped-form rendering, card styles, permission and shortcut placement, validation, search indexing, custom-view lifetime, and cache invalidation.

Plugins own current values, localized labels and descriptions, control actions, business state, and custom content for interactions that cannot be represented by standard controls.

## Surfaces

`PluginSettingsPage.form` is the default. Rows support toggles, pickers, sliders, text and secure fields, actions, and statuses. A form may include a custom section or place a shortcut group. Every form uses the same host-owned grouped `Form`; adding custom content never switches the whole page to a hand-built card renderer. A custom section chooses `.standard` or `.edgeToEdge` placement, and may contribute a lazy trailing header accessory, but the host continues to own its header, footer, visibility, insets, and outer card.

`PluginSettingsPage.workspace` is for task-oriented screens such as cleanup browsers, package managers, launch-item managers, and configuration editors. It receives the same host page scaffold and explicitly declares whether vertical scrolling is `.host` or `.selfManaged`; exactly one layer owns scrolling. Workspace cards use SwiftUI semantic backgrounds rather than drawing `NSColor.controlBackgroundColor` directly.

Page-wide observation and cleanup use `PluginSettingsPage.onVisibilityChange`, which the host invokes at the detail-page boundary. Section views never own page lifetime because grouped Form may create and recycle them lazily.

The manifest declares `capabilities.settings` as `none`, `form`, or `workspace`. The host reads a settings page only when declared and refuses a page whose runtime layout differs from the manifest.

## Actions and performance

Controls emit typed `PluginSettingsAction` values. Boolean, selection, and invoke actions rebuild derived state immediately. Numeric and text edits carry `.changed` or `.committed`; only committed changes rebuild the full host hierarchy. Plugins may still update their local snapshots during `.changed`.

Custom sections and workspaces are created lazily and cached with a structured key containing the plugin ID and exact surface. Dirty state, uninstall, isolation, localization changes, and layout removal invalidate the matching entries.

## Validation and search

The host validates non-empty and unique section, row, and option IDs; picker selections; slider values and steps; and shortcut-group existence and single placement. Invisible rows are neither rendered nor indexed.

Declarative search indexes titles, descriptions, keywords, and picker option labels. It never indexes current text-field or secure-field values. Custom content continues to provide explicit search entries and anchors.

## Compatibility and release

PluginKit 4 is an ABI break. MacTools 1.2.0 loads only v4 binaries. Every plugin manifest increases its package version, declares `minHostVersion` 1.2.0, and uses catalog schema 2.

The package store tolerantly decodes the outer capabilities of an installed v3 manifest so the catalog manager can identify and update it. No v3 settings model, view, or action compatibility remains. Older app releases continue using their existing versioned catalogs; publishing the v4 catalog is a separate signed release operation.
