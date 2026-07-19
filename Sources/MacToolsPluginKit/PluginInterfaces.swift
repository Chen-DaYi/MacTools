import Foundation
import SwiftUI

@MainActor
public protocol MacToolsPlugin: AnyObject {
    var metadata: PluginMetadata { get }
    var primaryPanel: (any PluginPrimaryPanel)? { get }
    var componentPanel: (any PluginComponentPanel)? { get }
    var permissionRequirements: [PluginPermissionRequirement] { get }
    var settingsSections: [PluginSettingsSection] { get }
    var shortcutDefinitions: [PluginShortcutDefinition] { get }
    var configuration: PluginConfiguration? { get }
    var onStateChange: (() -> Void)? { get set }
    var requestPermissionGuidance: ((String) -> Void)? { get set }
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)? { get set }

    func refresh()
    func activate(context: PluginRuntimeContext)
    func deactivate(reason: PluginDeactivationReason)
    func permissionState(for permissionID: String) -> PluginPermissionState
    func handlePermissionAction(id: String)
    func handleSettingsAction(id: String)
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

    var settingsSections: [PluginSettingsSection] {
        []
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        []
    }

    var configuration: PluginConfiguration? {
        nil
    }

    func refresh() {}

    func activate(context: PluginRuntimeContext) {}

    func deactivate(reason: PluginDeactivationReason) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
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

/// Optional protocol for plugins that expose a compact, read-only status in the primary panel row.
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginPrimaryPanelIndicatorProviding: AnyObject {
    var primaryPanelIndicator: PluginPrimaryPanelIndicator? { get }
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
/// Does not change the `MacToolsPlugin` witness table, so installed legacy plugins are unaffected.
@MainActor
public protocol PluginConfigurationPresenting: AnyObject {
    /// Host-injected callback requesting presentation of this plugin's settings page.
    var requestConfigurationPresentation: (() -> Void)? { get set }
}

/// Legacy PluginKit v3 compatibility surface.
///
/// The host no longer ties plugin lifecycle to Dashboard or Feature Panel
/// visibility, but previously released plugin binaries still reference this
/// protocol descriptor. Keep the declaration until the next PluginKit ABI
/// version so those installed packages continue to load.
@MainActor
public protocol PluginFeatureVisibilityLifecycleHandling: AnyObject {
    func featureVisibilityDidChange(_ isVisible: Bool)
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
