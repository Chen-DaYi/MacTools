import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

protocol MenuBarCommandRunning {
    func setMenuBarAutohide(_ isEnabled: Bool) throws
}

struct ProcessMenuBarCommandRunner: MenuBarCommandRunning {
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func setMenuBarAutohide(_ isEnabled: Bool) throws {
        let script = """
        tell application "System Events"
            tell dock preferences
                set autohide menu bar to \(isEnabled ? "true" : "false")
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AutoHideMenuBarPlugin",
                code: (error[NSAppleScript.errorNumber] as? Int) ?? 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : localization.string(
                            "error.toggleFailed",
                            defaultValue: "切换菜单栏自动隐藏失败"
                        )
                ]
            )
        }
    }
}

public final class AutoHideMenuBarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoHideMenuBarPluginProvider(context: context)
    }
}

@MainActor
private struct AutoHideMenuBarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoHideMenuBarPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class AutoHideMenuBarPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "AutoHideMenuBarPlugin")
    private let commandRunner: any MenuBarCommandRunning
    private let stateReader: () -> Bool
    private let localization: PluginLocalization

    private var isMenuBarHidden: Bool
    private var lastErrorMessage: String?

    init(
        commandRunner: (any MenuBarCommandRunning)? = nil,
        stateReader: @escaping () -> Bool = { AutoHideMenuBarPlugin.readMenuBarAutohideState() },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.commandRunner = commandRunner ?? ProcessMenuBarCommandRunner(localization: localization)
        self.stateReader = stateReader
        self.metadata = PluginMetadata(
            id: "auto-hide-menu-bar",
            title: localization.string("metadata.title", defaultValue: "自动隐藏菜单栏"),
            iconName: "menubar.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 42,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动隐藏菜单栏，提供更完整的屏幕显示空间"
            )
        )
        self.isMenuBarHidden = stateReader()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isMenuBarHidden
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isMenuBarHidden,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        let latestState = stateReader()
        if latestState != isMenuBarHidden {
            isMenuBarHidden = latestState
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        setMenuBarHidden(isEnabled)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private func setMenuBarHidden(_ isEnabled: Bool) {
        do {
            try commandRunner.setMenuBarAutohide(isEnabled)
            isMenuBarHidden = isEnabled
            lastErrorMessage = nil
            onStateChange?()
        } catch {
            logger.error("Failed to update menu bar auto-hide: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            refresh()
            onStateChange?()
        }
    }

    nonisolated static func readMenuBarAutohideState(
        globalDefaults: UserDefaults = .standard,
        dockDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dock")
    ) -> Bool {
        resolvedMenuBarAutohideState(
            globalValue: globalDefaults.object(forKey: "_HIHideMenuBar"),
            dockValue: dockDefaults?.object(forKey: "autohide-menubar")
        )
    }

    nonisolated static func resolvedMenuBarAutohideState(globalValue: Any?, dockValue: Any?) -> Bool {
        if let value = boolValue(from: globalValue) {
            return value
        }

        if let value = boolValue(from: dockValue) {
            return value
        }

        return false
    }

    private nonisolated static func boolValue(from value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        default:
            nil
        }
    }
}
