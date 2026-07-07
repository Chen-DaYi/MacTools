import AppKit
import SwiftUI
import MacToolsPluginKit

public final class ActivityBarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ActivityBarPluginProvider(context: context)
    }
}

@MainActor
private struct ActivityBarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            ActivityBarPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class ActivityBarPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel {
    private enum ControlID {
        static let trackingEnabled = "tracking-enabled"
        static let installHooks = "install-hooks"
        static let resetToday = "reset-today"
        static let openInputMonitoring = "open-input-monitoring"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    let descriptor = PluginComponentDescriptor(
        span: PluginComponentSpan(
            width: 4,
            height: PluginComponentPanelLayoutMetrics.default.heightSpan(closestToOriginalSpanHeight: 10)
        )!
    )

    private let localization: PluginLocalization
    private let controller: ActivityBarController
    private var isExpanded = false

    var onStateChange: (() -> Void)? {
        didSet {
            controller.onStateChange = onStateChange
        }
    }
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(
        context: PluginRuntimeContext,
        controller: ActivityBarController? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: ActivityBarController.pluginID,
            title: localization.string("metadata.title", defaultValue: "活动统计"),
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            order: 18,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "统计输入、前台应用使用时长和 AI 编程活动"
            )
        )
        self.controller = controller ?? ActivityBarController(context: context, localization: localization)
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: controller.panelSubtitle,
            isOn: controller.isTrackingEnabled,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? panelDetail : nil,
            errorMessage: controller.lastErrorMessage
        )
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: controller.componentSubtitle,
            isActive: controller.isTrackingEnabled,
            isEnabled: true,
            isVisible: true,
            errorMessage: controller.lastErrorMessage
        )
    }

    var settingsSections: [PluginSettingsSection] {
        [
            PluginSettingsSection(
                id: "input-monitoring",
                title: localization.string("settings.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "settings.inputMonitoring.description",
                    defaultValue: "用于统计键盘、鼠标点击和滚动事件。"
                ),
                status: inputMonitoringSettingsStatus,
                footnote: controller.inputMonitoringFootnote,
                buttonTitle: localization.string("settings.inputMonitoring.button", defaultValue: "打开系统设置"),
                actionID: ControlID.openInputMonitoring
            ),
            PluginSettingsSection(
                id: "ai-hooks",
                title: localization.string("settings.aiHooks.title", defaultValue: "AI 工具 Hook"),
                description: localization.string(
                    "settings.aiHooks.description",
                    defaultValue: "记录 Claude Code、Cursor 和 Codex 的提示、工具调用与执行时长。"
                ),
                status: hookSettingsStatus,
                footnote: controller.hookInstallFootnote,
                buttonTitle: localization.string("settings.aiHooks.button", defaultValue: "安装或更新 Hook"),
                actionID: ControlID.installHooks
            )
        ]
    }

    func activate(context: PluginRuntimeContext) {
        controller.activate(context: context)
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.deactivate(reason: reason)
    }

    func refresh() {
        controller.refresh()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            controller.setTrackingEnabled(isEnabled)
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            handleAction(controlID: controlID)
        case .setSelection, .setNavigationSelection,
             .clearNavigationSelection, .setDate, .setSlider:
            return
        }
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(
            ActivityBarComponentView(
                controller: controller,
                localization: localization,
                dismiss: context.dismiss
            )
        )
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}

    func handleSettingsAction(id: String) {
        handleAction(controlID: id)
    }

    func handleShortcutAction(id: String) {}

    private var panelDetail: PluginPanelDetail {
        let trackingControl = PluginPanelControl(
            id: ControlID.trackingEnabled,
            kind: .switchRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.trackingEnabled", defaultValue: "活动统计"),
            actionIconSystemName: "chart.bar.xaxis",
            isEnabled: true
        )

        let openSettingsControl = PluginPanelControl(
            id: ControlID.openInputMonitoring,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openInputMonitoring", defaultValue: "打开输入监控设置"),
            actionIconSystemName: "keyboard.badge.eye",
            isEnabled: true
        )

        let installHooksControl = PluginPanelControl(
            id: ControlID.installHooks,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.installHooks", defaultValue: "安装或更新 AI Hook"),
            actionIconSystemName: "terminal",
            isEnabled: true
        )

        let resetControl = PluginPanelControl(
            id: ControlID.resetToday,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.resetToday", defaultValue: "清空今日统计"),
            actionIconSystemName: "arrow.counterclockwise",
            showsLeadingDivider: true,
            isEnabled: true
        )

        return PluginPanelDetail(
            primaryControls: [trackingControl, openSettingsControl, installHooksControl, resetControl],
            secondaryPanel: nil
        )
    }

    private var inputMonitoringSettingsStatus: PluginSettingsSection.Status {
        switch controller.monitorStatus {
        case .running:
            return PluginSettingsSection.Status(
                text: localization.string("status.running", defaultValue: "运行中"),
                systemImage: "checkmark.circle.fill",
                tone: .positive
            )
        case .inputMonitoringDenied:
            return PluginSettingsSection.Status(
                text: localization.string("status.permissionRequired", defaultValue: "需要授权"),
                systemImage: "exclamationmark.triangle.fill",
                tone: .caution
            )
        case .idle:
            return PluginSettingsSection.Status(
                text: localization.string("status.disabled", defaultValue: "未开启"),
                systemImage: "pause.circle",
                tone: .neutral
            )
        }
    }

    private var hookSettingsStatus: PluginSettingsSection.Status {
        switch controller.hookInstallState {
        case .installed:
            return PluginSettingsSection.Status(
                text: localization.string("hook.status.installed", defaultValue: "已安装"),
                systemImage: "checkmark.circle.fill",
                tone: .positive
            )
        case .failed:
            return PluginSettingsSection.Status(
                text: localization.string("hook.status.installFailed", defaultValue: "安装失败"),
                systemImage: "exclamationmark.triangle.fill",
                tone: .caution
            )
        case .notInstalled:
            return PluginSettingsSection.Status(
                text: localization.string("hook.status.notInstalled", defaultValue: "未安装"),
                systemImage: "terminal",
                tone: .neutral
            )
        }
    }

    private func handleAction(controlID: String) {
        switch controlID {
        case ControlID.installHooks:
            controller.installHooks()
        case ControlID.resetToday:
            controller.resetToday()
        case ControlID.openInputMonitoring:
            controller.openInputMonitoringSettings()
        default:
            break
        }
    }
}
