import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class IPOverviewPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        IPOverviewPluginProvider(context: context)
    }
}

@MainActor
private struct IPOverviewPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [IPOverviewPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class IPOverviewPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginConfigurationPresenting {
    enum ControlID {
        static let openSettings = "execute"
        static let copyIP = "ip-overview-copy-ip"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    private let viewModel: IPOverviewViewModel
    private let localization: PluginLocalization

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestConfigurationPresentation: (() -> Void)?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "ip-overview"),
        viewModel: IPOverviewViewModel? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.viewModel = viewModel ?? IPOverviewViewModel(storage: context.storage, localization: localization)
        self.metadata = PluginMetadata(
            id: "ip-overview",
            title: localization.string("metadata.title", defaultValue: "IP 检测"),
            iconName: "network",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看公网 IP、本地地址和归属地"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: localization.string("panel.button.check", defaultValue: "检测")
        )
        self.viewModel.onSnapshotChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    func activate(context: PluginRuntimeContext) {
        viewModel.refreshIfNeeded()
    }

    func deactivate(reason: PluginDeactivationReason) {
        viewModel.cancel()
    }

    func refresh() {
        viewModel.refreshPublicIP()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: viewModel.snapshot.isRefreshing,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: viewModel.snapshot.errorMessage
        )
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(
            description: metadata.defaultDescription,
            prefersFullHeight: true
        ) { _ in
            IPOverviewComponentView(
                viewModel: self.viewModel,
                localization: self.localization,
                startsInDetails: true,
                showsBackButton: false
            )
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setDisclosureExpanded,
             .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    private var panelSubtitle: String {
        let snapshot = viewModel.snapshot
        if snapshot.isRefreshing {
            return localization.string("panel.subtitle.refreshing", defaultValue: "正在检测公网 IP...")
        }

        if let ip = snapshot.preferredPublicIP?.ip {
            return viewModel.hidesSensitiveInfo ? IPOverviewSensitiveValueMask.maskedIP(ip) : ip
        }

        if let errorMessage = snapshot.errorMessage {
            return errorMessage
        }

        return metadata.defaultDescription
    }

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.openSettings:
            requestConfigurationPresentation?()
        case ControlID.copyIP:
            viewModel.copy(viewModel.snapshot.preferredPublicIP?.ip)
        default:
            break
        }
    }
}
