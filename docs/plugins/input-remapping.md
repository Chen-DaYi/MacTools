# Input Remapping Plugin

## Purpose

- User-facing name: Custom Shortcuts.
- Inputs: keyboard, mouse, scroll, precise Trackpad Gestures catalog.
- Outputs: shortcuts, mouse navigation, common macOS actions.

## Manifest

- ID: `input-remapping`.
- Settings layout: `workspace`.
- Permissions: Accessibility, Input Monitoring.
- `pluginKitVersion`: `5`.

## Shared trackpad gestures

- Trackpad Gestures owns the private multitouch listener.
- Input Remapping consumes the shared `TrackpadGestureEventConsuming` bridge.
- The last enabled mapping owns a gesture at runtime; conflicting mappings remain saved, inactive, and marked as already used by another plugin.
- External TipTap claims resolve their native click as consumed before dispatching the shortcut action.

## Validation

- `make build-plugin PLUGIN=input-remapping`
- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -only-testing:MacToolsTests/InputRemappingModelsTests -quiet`
