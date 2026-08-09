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
final class AutoInputPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginApplicationActivityStateHandling {
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
        applicationMonitor: AutoInputApplicationMonitoring? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let store = AutoInputStore(storage: context.storage)
        let controller = AutoInputController(
            store: store,
            sourceController: sourceController ?? CarbonAutoInputSourceCatalog(),
            applicationMonitor: applicationMonitor ?? WorkspaceAutoInputApplicationMonitor(),
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
            isOn: store.isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: controller.errorMessage
        )
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

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(value) = action else { return }
        store.setEnabled(value)
        controller.configurationDidChange()
        onStateChange?()
    }

    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState) {
        controller.setInteractive(state.allowsBackgroundWork)
    }

    private var panelSubtitle: String {
        guard store.isEnabled else {
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
}
