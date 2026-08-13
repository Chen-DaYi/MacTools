import Foundation
import SwiftUI

@MainActor
public protocol MacToolsPlugin: AnyObject {
    var metadata: PluginMetadata { get }
    var primaryPanel: (any PluginPrimaryPanel)? { get }
    var componentPanel: (any PluginComponentPanel)? { get }
    var permissionRequirements: [PluginPermissionRequirement] { get }
    var shortcutDefinitions: [PluginShortcutDefinition] { get }
    var settingsPage: PluginSettingsPage? { get }
    var onStateChange: (() -> Void)? { get set }
    var requestPermissionGuidance: ((String) -> Void)? { get set }
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? { get set }

    func refresh()
    func activate(context: PluginRuntimeContext)
    func deactivate(reason: PluginDeactivationReason)
    func permissionState(for permissionID: String) -> PluginPermissionState
    func handlePermissionAction(id: String)
    func handleSettingsAction(_ action: PluginSettingsAction)
    func handleShortcutAction(id: String)
}

@MainActor
public protocol PluginPrimaryPanel: AnyObject {
    var primaryPanelDescriptor: PluginPrimaryPanelDescriptor { get }
    var primaryPanelState: PluginPanelState { get }

    func handleAction(_ action: PluginPanelAction)
}

public enum PluginShortcutEventPhase: Sendable {
    case pressed
    case released
}

@MainActor
public protocol PluginShortcutEventHandling: AnyObject {
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase)
}

public extension MacToolsPlugin {
    var primaryPanel: (any PluginPrimaryPanel)? {
        nil
    }

    var componentPanel: (any PluginComponentPanel)? {
        nil
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        []
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        []
    }

    var settingsPage: PluginSettingsPage? {
        nil
    }

    func refresh() {}

    func activate(context: PluginRuntimeContext) {}

    func deactivate(reason: PluginDeactivationReason) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}

public extension MacToolsPlugin where Self: PluginPrimaryPanel {
    var primaryPanel: (any PluginPrimaryPanel)? {
        self
    }
}

@MainActor
public protocol PluginComponentPanel: AnyObject {
    var descriptor: PluginComponentDescriptor { get }
    var componentPanelState: PluginComponentState { get }

    func makeView(context: PluginComponentContext) -> AnyView
}

public extension MacToolsPlugin where Self: PluginComponentPanel {
    var componentPanel: (any PluginComponentPanel)? {
        self
    }
}

public enum PluginPanelSurface: CaseIterable, Hashable, Sendable {
    case component
    case primary
}

@MainActor
public protocol PluginPanelSurfaceLifecycleHandling: AnyObject {
    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface)
    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface)
}

public extension PluginPanelSurfaceLifecycleHandling {
    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {}
    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {}
}

@MainActor
public protocol PluginProvider {
    func makePlugins() -> [any MacToolsPlugin]
}

public protocol MacToolsPluginBundleFactory: AnyObject {
    static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider
}

@MainActor
public protocol AccessibilityPermissionRefreshing {
    func refreshAccessibilityPermission()
}

@MainActor
public protocol DisplayTopologyRefreshing {
    func refreshDisplayTopology()
}

/// Optional preflight contract for a plugin that takes ownership of behavior extracted from
/// another package. This is a separate protocol so existing plugin witness tables remain stable.
@MainActor
public protocol PluginFeatureExtractionReadinessProviding: AnyObject {
    func validateFeatureExtractionReadiness() throws
}

/// Optional protocol for plugins that expose a compact, read-only status in the primary panel row.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginPrimaryPanelIndicatorProviding: AnyObject {
    var primaryPanelIndicator: PluginPrimaryPanelIndicator? { get }
}

/// Optional protocol for plugins that expose one or more icon-only statuses in the primary panel row.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginPrimaryPanelCompactIndicatorProviding: AnyObject {
    var primaryPanelCompactIndicator: PluginPrimaryPanelCompactIndicator? { get }
}

/// Optional protocol for plugins that need a floating-window anchor.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol DropZoneAnchorProviding: AnyObject {
    /// Host-injected provider returning the status-item button frame in screen coordinates.
    var anchorRectProvider: (() -> NSRect?)? { get set }
}

/// Optional protocol for plugins that need to protect the host menu-bar status-item position.
@MainActor
public protocol MenuBarHostStatusItemRecovering: AnyObject {
    var hostStatusItemFrameProvider: (() -> NSRect?)? { get set }
    var resetHostStatusItemPosition: (() -> Void)? { get set }
}

/// Optional protocol for plugins that need to open their settings page from custom UI, such as a floating panel.
@MainActor
public protocol PluginSettingsPresenting: AnyObject {
    var requestSettingsPresentation: (() -> Void)? { get set }
}

/// Optional hook for built-in plugins that cache localized descriptors or
/// other language-dependent presentation data. The host invokes it when the
/// app language changes; implementations must not activate, deactivate, or
/// reset the plugin's functional state. Dynamic plugins read localization at
/// render time and do not need this hook.
@MainActor
public protocol PluginRuntimeLocalizationRefreshing: AnyObject {
    func refreshLocalization()
}

/// Optional hook for plugins whose dynamic shortcut definitions need to retain a shortcut after
/// the host accepts, clears, or restores its binding. Registration and conflict validation remain
/// owned by the host's shared shortcut manager.
@MainActor
public protocol PluginShortcutBindingChangeHandling: AnyObject {
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?)
}

/// Optional protocol for plugins that explicitly opt a small, non-sensitive settings payload
/// into MacTools preferences backup and restore. This preserves the `MacToolsPlugin` ABI for
/// existing dynamic plugins while keeping cache, credentials, and other private data excluded.
@MainActor
public protocol PluginPortablePreferencesProviding: AnyObject {
    func makePortablePreferencesBackup() -> Data?
    func restorePortablePreferences(from data: Data)
}

/// Optional bridge for the sole owner of the private multitouch listener.
@MainActor
public protocol TrackpadGestureEventProviding: AnyObject {
    var onTrackpadGestureMappingsChange: (() -> Void)? { get set }
    func setExternalGestureClaims(
        _ gestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    )
    func removeLocalMapping(for gesture: TrackpadGesture)
}

/// Optional bridge for a plugin that maps the shared precise trackpad gestures.
@MainActor
public protocol TrackpadGestureEventConsuming: AnyObject {
    var claimedTrackpadGestures: Set<TrackpadGesture> { get }
    var onTrackpadGestureClaimsChange: (() -> Void)? { get set }
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)? { get set }
    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64)
}
