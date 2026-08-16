import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class AutoInputPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AutoInputPluginProvider(context: context)
    }
}

@MainActor
private struct AutoInputPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AutoInputPlugin(context: context)]
    }
}

@MainActor
final class AutoInputPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginApplicationActivityStateHandling,
    PluginActionProviding
{
    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum ActionID {
        static let setEnabled = "set-enabled"
        static let toggle = "toggle"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let store: AutoInputStore
    private let controller: AutoInputController
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "auto-input"),
        sourceController: AutoInputSourceControlling? = nil,
        applicationMonitor: AutoInputApplicationMonitoring? = nil,
        focusObserver: AutoInputFocusObserving? = nil,
        hudPresenter: InputSourceHUDPresenting? = nil,
        hudLabelResolver: InputSourceHUDLabelResolving? = nil,
        accessibilityCheck: AutoInputAccessibilityChecking? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let store = AutoInputStore(storage: context.storage)
        let controller = AutoInputController(
            store: store,
            sourceController: sourceController ?? CarbonAutoInputSourceCatalog(),
            applicationMonitor: applicationMonitor ?? WorkspaceAutoInputApplicationMonitor(),
            focusObserver: focusObserver ?? AccessibilityAutoInputFocusObserver(),
            hudPresenter: hudPresenter ?? InputSourceHUDController(),
            hudLabelResolver: hudLabelResolver ?? StandardInputSourceHUDLabelResolver(),
            accessibilityCheck: accessibilityCheck ?? SystemAutoInputAccessibilityCheck(),
            switchErrorMessage: {
                localization.string("error.switchFailed", defaultValue: "无法切换输入法")
            }
        )
        self.localization = localization
        self.store = store
        self.controller = controller
        self.metadata = PluginMetadata(
            id: "auto-input",
            title: localization.string("metadata.title", defaultValue: "自动切换输入法"),
            iconName: "keyboard",
            iconTint: Color(nsColor: .systemBlue),
            order: 66,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "按应用记住并自动切换输入法"
            )
        )
        controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: store.isAutoSwitchEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: persistenceErrorMessage ?? controller.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        guard store.isInputHUDEnabled else { return [] }
        return [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "仅用于在文本输入区域和终端附近显示当前输入法。"
                )
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "behavior",
                title: localization.string("settings.behavior.title", defaultValue: "切换行为"),
                systemImage: "character.cursor.ibeam",
                presentation: .edgeToEdge
            ) { [self] _ in
                AutoInputSettingsView(
                    store: store,
                    controller: controller,
                    localization: localization,
                    onChange: { [weak self] in
                        self?.controller.configurationDidChange()
                        self?.onStateChange?()
                    },
                    onHUDChange: { [weak self] enabled in
                        self?.controller.configurationDidChange(
                            promptForAccessibility: enabled
                        )
                        self?.onStateChange?()
                    },
                    section: .behavior
                )
            },
            PluginSettingsSection(
                id: "rules",
                title: localization.string("settings.rules.title", defaultValue: "固定规则"),
                systemImage: "app.badge.checkmark",
                presentation: .edgeToEdge
            ) { [self] _ in
                AutoInputSettingsView(
                    store: store,
                    controller: controller,
                    localization: localization,
                    onChange: { [weak self] in
                        self?.controller.configurationDidChange()
                        self?.onStateChange?()
                    },
                    onHUDChange: { _ in },
                    section: .rules
                )
            }
            .headerAccessory { [self] _ in
                Button {
                    AutoInputSettingsView.addApplication(
                        store: self.store,
                        controller: self.controller,
                        localization: self.localization,
                        onChange: { [weak self] in
                            self?.controller.configurationDidChange()
                            self?.onStateChange?()
                        }
                    )
                } label: {
                    Label(
                        localization.string("settings.rules.add", defaultValue: "添加"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.sources.isEmpty)
            }
        ])
        .onVisibilityChange { [weak self] isVisible in
            self?.controller.settingsVisibilityDidChange(isVisible)
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription],
                systemImage: metadata.iconName,
                parameters: [
                    ActionParameterDefinition(
                        id: "enabled",
                        title: metadata.title,
                        kind: .boolean
                    ),
                ],
                externalInvocationPolicy: .allowed,
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: toggleActionReference,
                title: store.isAutoSwitchEnabled
                    ? localization.string("action.disable.title", defaultValue: "暂停自动切换输入法")
                    : localization.string("action.enable.title", defaultValue: "开启自动切换输入法"),
                subtitle: panelSubtitle,
                presentationState: store.isAutoSwitchEnabled ? .active : .inactive
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: true),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.remembering", defaultValue: "自动记忆已开启"))"
            ),
            ActionCatalogEntry(
                reference: actionReference(enabled: false),
                title: "\(metadata.title) · \(localization.string("panel.subtitle.paused", defaultValue: "已暂停"))"
            ),
        ]
    }

    func activate(context: PluginRuntimeContext) {
        controller.start()
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.stop()
    }

    func refresh() {
        controller.refresh()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: controller.isAccessibilityGranted,
            footnote: controller.isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。自动切换输入法不受影响。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }
        _ = controller.requestAccessibilityPermission()
        if !controller.isAccessibilityGranted {
            requestPermissionGuidance?(PermissionID.accessibility)
        }
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(value) = action else { return }
        _ = setAutoSwitchEnabled(value)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        switch invocation.reference.key.actionID {
        case ActionID.toggle:
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                return self.setAutoSwitchEnabled(!self.store.isAutoSwitchEnabled)
            }
        case ActionID.setEnabled:
            guard case let .boolean(value)? = invocation.reference.parameters["enabled"] else {
                return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
            }
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                return self.setAutoSwitchEnabled(value)
            }
        default:
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        controller.setInteractive(state.allowsBackgroundWork)
    }

    private var panelSubtitle: String {
        guard store.isAutoSwitchEnabled else {
            return localization.string("panel.subtitle.paused", defaultValue: "已暂停")
        }
        if !store.rules.isEmpty {
            return localization.format(
                "panel.subtitle.rulesFormat",
                defaultValue: "%d 条固定规则",
                store.rules.count
            )
        }
        if store.remembersLastInputSource {
            return localization.string("panel.subtitle.remembering", defaultValue: "自动记忆已开启")
        }
        return localization.string("panel.subtitle.noRules", defaultValue: "暂无切换规则")
    }

    private func actionReference(enabled: Bool) -> ActionReference {
        ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.setEnabled),
            parameters: try! ActionParameterSet(["enabled": .boolean(enabled)])
        )
    }

    private var toggleActionReference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: ActionID.toggle))
    }

    private var persistenceErrorMessage: String? {
        guard case let .rejected(rollbackSucceeded)? = store.persistenceFailure else {
            return nil
        }
        return rollbackSucceeded
            ? localization.string(
                "error.persistenceFailed",
                defaultValue: "无法保存自动切换输入法设置。"
            )
            : localization.string(
                "error.persistenceRollbackFailed",
                defaultValue: "无法保存自动切换输入法设置，且恢复先前设置失败。"
            )
    }

    private func setAutoSwitchEnabled(_ enabled: Bool) -> ActionExecutionResult {
        guard store.setAutoSwitchEnabled(enabled) == .committed else {
            onStateChange?()
            return .failed(message: persistenceErrorMessage ?? PluginKitLocalization.actionUnavailable)
        }
        controller.configurationDidChange()
        onStateChange?()
        return .succeeded()
    }
}
