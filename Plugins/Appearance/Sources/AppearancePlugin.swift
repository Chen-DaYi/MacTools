import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class AppearancePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppearancePluginProvider(context: context)
    }
}

@MainActor
private struct AppearancePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AppearancePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AppearancePlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AppearancePlugin")
    private let localization: PluginLocalization
    private var isDarkMode: Bool = false
    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "appearance",
            title: localization.string("metadata.title", defaultValue: "深色模式"),
            iconName: "circle.lefthalf.filled",
            iconTint: Color(nsColor: .systemIndigo),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "切换系统亮色与深色外观"
            )
        )
        isDarkMode = Self.readSystemDarkMode()
        observeSystemAppearanceChanges()
    }

    deinit {
        if let observer = themeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isDarkMode
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isDarkMode,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    func refresh() {
        let current = Self.readSystemDarkMode()
        if current != isDarkMode {
            isDarkMode = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        setDarkMode(enable)
    }

    // MARK: - Private

    private static func readSystemDarkMode() -> Bool {
        let style = UserDefaults(suiteName: ".GlobalPreferences")?.string(forKey: "AppleInterfaceStyle")
        return style == "Dark"
    }

    private func setDarkMode(_ enable: Bool) {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enable ? "true" : "false")
            end tell
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            logger.error("Failed to set dark mode: \(error)")
        } else {
            isDarkMode = enable
            onStateChange?()
        }
    }

    private func observeSystemAppearanceChanges() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let current = Self.readSystemDarkMode()
                if current != self.isDarkMode {
                    self.isDarkMode = current
                    self.onStateChange?()
                }
            }
        }
    }
}
