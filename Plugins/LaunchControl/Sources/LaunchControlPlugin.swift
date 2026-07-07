import Foundation
import SwiftUI
import MacToolsPluginKit

public final class LaunchControlPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchControlPluginProvider(context: context)
    }
}

@MainActor
private struct LaunchControlPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = LaunchControlController(context: context, localization: localization)
        return [LaunchControlPlugin(context: context, controller: controller, localization: localization)]
    }
}

@MainActor
final class LaunchControlPlugin: MacToolsPlugin, PluginPrimaryPanel {
    enum ControlID {
        static let refresh = "launch-control-refresh"
        static let openManager = "launch-control-open-manager"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let controller: LaunchControlController
    private let localization: PluginLocalization
    private var isExpanded = false

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "launch-control"),
        controller: LaunchControlController? = nil,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.controller = controller ?? LaunchControlController(context: context, localization: localization)
        self.metadata = PluginMetadata(
            id: "launch-control",
            title: localization.string("metadata.title", defaultValue: "启动项"),
            iconName: "powerplug",
            iconTint: Color(nsColor: .systemOrange),
            order: 95,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看和管理 launchctl 启动项"
            )
        )
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var primaryPanelState: PluginPanelState {
        let snapshot = controller.snapshot
        return PluginPanelState(
            subtitle: subtitle(for: snapshot),
            isOn: snapshot.isRefreshing,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: snapshot) : nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var configuration: PluginConfiguration? {
        let localization = localization
        return PluginConfiguration(description: metadata.defaultDescription) { _ in
            LaunchControlManagerView(controller: self.controller, localization: localization)
        }
    }

    func refresh() {
        if controller.snapshot.items.isEmpty {
            controller.refresh()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.cancelRefresh()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            if controlID == ControlID.refresh {
                controller.refresh()
            }
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private func buildDetail(for snapshot: LaunchControlSnapshot) -> PluginPanelDetail {
        let refreshControl = PluginPanelControl(
            id: ControlID.refresh,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: snapshot.isRefreshing
                ? localization.string("panel.action.refreshing", defaultValue: "正在刷新")
                : localization.string("panel.action.refresh", defaultValue: "刷新列表"),
            actionIconSystemName: "arrow.clockwise",
            isEnabled: !snapshot.isRefreshing
        )

        let openManagerControl = PluginPanelControl(
            id: ControlID.openManager,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openManager", defaultValue: "打开管理器"),
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )

        return PluginPanelDetail(primaryControls: [refreshControl, openManagerControl], secondaryPanel: nil)
    }

    private func subtitle(for snapshot: LaunchControlSnapshot) -> String {
        if snapshot.isRefreshing {
            return localization.string(
                "panel.subtitle.refreshing",
                defaultValue: "正在扫描 LaunchAgent 与 LaunchDaemon"
            )
        }

        if snapshot.items.isEmpty {
            return localization.string(
                "panel.subtitle.empty",
                defaultValue: "打开管理器或刷新后查看启动项"
            )
        }

        let userCreatedCount = snapshot.items.filter { $0.origin == .userCreated }.count
        let runningCount = snapshot.items.filter { $0.state == .running }.count
        return localization.format(
            "panel.subtitle.summary",
            defaultValue: "%d 项 · %d 运行中 · %d 用户创建",
            snapshot.items.count,
            runningCount,
            userCreatedCount
        )
    }
}
