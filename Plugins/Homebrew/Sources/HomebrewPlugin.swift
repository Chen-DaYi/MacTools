import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class HomebrewPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        HomebrewPluginProvider(context: context)
    }
}

@MainActor
private struct HomebrewPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = HomebrewController(localization: localization)
        return [HomebrewPlugin(
            controller: controller,
            localization: localization
        )]
    }
}

@MainActor
public final class HomebrewPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginConfigurationPresenting {
    public enum ControlID {
        static let manage = "execute"
    }

    public let metadata: PluginMetadata
    public let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    public var onStateChange: (() -> Void)?
    public var requestPermissionGuidance: ((String) -> Void)?
    public var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    public var requestConfigurationPresentation: (() -> Void)?

    private let controller: HomebrewController
    private let localization: PluginLocalization

    public init(
        controller: HomebrewController,
        localization: PluginLocalization
    ) {
        self.controller = controller
        self.localization = localization
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: localization.string("panel.action.manage", defaultValue: "管理")
        )
        
        self.metadata = PluginMetadata(
            id: "homebrew",
            title: localization.string("metadata.title", defaultValue: "Homebrew"),
            iconName: "shippingbox.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 92,
            defaultDescription: localization.string("metadata.description", defaultValue: "Manage Homebrew packages, repositories, and perform diagnostics")
        )

        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    public func activate(context: PluginRuntimeContext) {
        onStateChange?()
    }

    public func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else { return }
        controller.cancelCurrentOperation()
    }

    public func refresh() {
        onStateChange?()
    }

    public var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitleText,
            isOn: controller.isBusy,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: controller.isBrewAvailable
                ? nil
                : localization.string("panel.error.brewPathRequired", defaultValue: "需要配置 brew 路径")
        )
    }

    public var permissionRequirements: [PluginPermissionRequirement] { [] }
    public var settingsSections: [PluginSettingsSection] { [] }
    public var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    public var configuration: PluginConfiguration? {
        let controller = self.controller
        let localization = self.localization
        return PluginConfiguration(
            description: metadata.defaultDescription,
            prefersFullHeight: true
        ) { _ in
            HomebrewDetailView(
                controller: controller,
                localization: localization,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 480
            )
        }
    }

    public func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        default:
            break
        }
    }

    public func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    public func handlePermissionAction(id: String) {}
    public func handleSettingsAction(id: String) {}
    public func handleShortcutAction(id: String) {}

    // MARK: - Private

    private var subtitleText: String {
        guard controller.isBrewAvailable else {
            return localization.string("panel.error.brewPathRequired", defaultValue: "需要配置 brew 路径")
        }
        if controller.isBusy {
            return controller.currentOperationName
        }
        return localization.string("panel.subtitle.manage", defaultValue: "管理包、软件源与诊断")
    }

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.manage:
            requestConfigurationPresentation?()
        default:
            break
        }
    }
}
