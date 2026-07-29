import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplaySleepPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplaySleepPluginProvider(context: context)
    }
}

@MainActor
private struct DisplaySleepPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplaySleepPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class DisplaySleepPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginCommandProviding {
    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DisplaySleepPlugin"
    )
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "display-sleep",
            title: localization.string("metadata.title", defaultValue: "显示器休眠"),
            iconName: "display",
            iconTint: Color(nsColor: .systemIndigo),
            order: 97,
            defaultDescription: localization.string("metadata.description", defaultValue: "立即让显示器休眠")
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.sleep", defaultValue: "休眠") }
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "execute",
                title: localization.string(
                    "metadata.title",
                    defaultValue: "显示器休眠"
                ),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即让显示器休眠"
                ),
                systemImage: metadata.iconName
            )
        ]
    }

    func handleCommand(id: String) {
        guard id == "execute" else {
            return
        }

        handleAction(.invokeAction(controlID: "execute"))
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else {
            return
        }

        sleepDisplays()
    }

    private func sleepDisplays() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]

        do {
            try task.run()
            logger.info("Requested display sleep via pmset")
        } catch {
            logger.error("Failed to invoke pmset displaysleepnow: \(error.localizedDescription)")
        }
    }
}
