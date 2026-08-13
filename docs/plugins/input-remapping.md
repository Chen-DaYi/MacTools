# Input Remapping Plugin

## Purpose

- User-facing name: Custom Shortcuts.
- Inputs: keyboard, mouse, scroll, precise Trackpad Gestures catalog.
- Outputs: shortcuts, mouse navigation, common macOS actions.

## Manifest

- ID: `input-remapping`.
- Settings layout: `workspace`.
- Permissions: Accessibility, Input Monitoring.
- `pluginKitVersion`: `4`.

## Shared trackpad gestures

- Trackpad Gestures owns the private multitouch listener.
- Input Remapping consumes the shared `TrackpadGestureEventConsuming` bridge.
- The last enabled mapping owns a gesture; the other plugin removes its conflicting mapping.
- External TipTap claims resolve their native click as consumed before dispatching the shortcut action.

## Validation

- `make build-plugin PLUGIN=input-remapping`
- `xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -only-testing:MacToolsTests/InputRemappingModelsTests -quiet`
