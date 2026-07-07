import CoreBrightness
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class NightShiftPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        NightShiftPluginProvider(context: context)
    }
}

@MainActor
private struct NightShiftPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [NightShiftPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

protocol NightShiftControlling {
    func getStatus() -> Bool
    func setEnabled(_ enabled: Bool) -> Bool
}

struct CBNightShiftController: NightShiftControlling {
    private let client = CBBlueLightClient()

    func getStatus() -> Bool {
        var status = CBBlueLightStatus()
        guard client.getBlueLightStatus(&status) else { return false }
        return status.enabled.boolValue
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        client.setEnabled(enabled)
    }
}

@MainActor
final class NightShiftPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "NightShiftPlugin")
    private let localization: PluginLocalization
    private let controller: any NightShiftControlling
    private var isEnabled: Bool
    private var lastErrorMessage: String?

    init(
        controller: any NightShiftControlling = CBNightShiftController(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller
        self.metadata = PluginMetadata(
            id: "night-shift",
            title: localization.string("metadata.title", defaultValue: "夜览"),
            iconName: "lamp.floor",
            iconTint: Color(nsColor: .systemOrange),
            order: 35,
            defaultDescription: localization.string("metadata.description", defaultValue: "降低蓝光，使屏幕颜色更暖")
        )
        self.isEnabled = controller.getStatus()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isEnabled
                ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
                : localization.string("panel.subtitle.disabled", defaultValue: "已关闭"),
            isOn: isEnabled,
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
        let current = controller.getStatus()
        if current != isEnabled {
            isEnabled = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        setNightShift(enable)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    private func setNightShift(_ enable: Bool) {
        let success = controller.setEnabled(enable)
        if success {
            isEnabled = enable
            lastErrorMessage = nil
            onStateChange?()
        } else {
            logger.error("Failed to \(enable ? "enable" : "disable", privacy: .public) Night Shift")
            lastErrorMessage = localization.string("error.toggleFailed", defaultValue: "切换夜览失败")
            onStateChange?()
        }
    }
}
