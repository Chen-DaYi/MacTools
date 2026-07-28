# App Volume Plugin

The App Volume plugin provides per-application output volume controls on macOS 15 or later. It discovers Core Audio processes that are currently producing output, groups helper processes under their responsible foreground application, and stores each app's preferred volume locally by bundle identifier.

## Audio Routing

For every app whose preferred volume is below 100%, the plugin creates a private Core Audio process tap and a private aggregate output route. The tap suppresses the app's original path only while MacTools is actively reading it. The real-time callback applies a short gain ramp and writes the adjusted PCM samples to the current output device. Returning an app to 100%, stopping playback, changing the output device, disabling the plugin, or quitting MacTools removes the route and restores the original path.

The first release supports standard two-channel output devices. It does not create a route when the current output layout cannot be confirmed as stereo, preventing an incompatible buffer layout from muting or corrupting multi-channel output.

## Privacy and Permission

macOS requires System Audio Recording permission before one app can process another app's audio. MacTools requests this permission only after the user moves an app below 100% or explicitly checks the permission card. Audio processing stays in the real-time Core Audio callback and is never recorded, saved, or uploaded.

## Development Validation

Generate the plugin targets and run the focused tests with:

```bash
make generate
xcodebuild \
  -project MacTools.xcodeproj \
  -scheme MacTools \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test \
  -only-testing:MacToolsTests/AppVolumePluginTests
```

Manual audio validation should cover built-in speakers, wired headphones, Bluetooth output, output-device switching while audio is playing, app termination, plugin disable, and permission denial.
