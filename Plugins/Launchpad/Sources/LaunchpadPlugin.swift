import Combine
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class LaunchpadPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LaunchpadPluginProvider(context: context)
    }
}

private struct LaunchpadPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            LaunchpadPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class LaunchpadPlugin: MacToolsPlugin, PluginPrimaryPanel {
    private enum ControlID {
        static let execute = "execute"
    }
    private enum ActionID {
        static let toggle = "toggleLaunchpad"
    }
    private enum ShortcutID {
        static let toggle = "launchpad.toggle"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadPlugin"
    )

    private let preferences: LaunchpadPreferences
    private let layoutStore: LaunchpadLayoutStore
    private let overlay: LaunchpadOverlayController
    private let localization: PluginLocalization
    private let hotCornerMonitor = LaunchpadHotCornerMonitor()
    private var cancellables = Set<AnyCancellable>()

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "launchpad",
            title: localization.string("metadata.title", defaultValue: "启动台"),
            iconName: "square.grid.3x3.fill",
            iconTint: Color(nsColor: .systemBlue),
            order: 12,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "唤出应用网格，搜索并启动"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: localization.string("panel.button.open", defaultValue: "打开")
        )
        let preferences = LaunchpadPreferences(storage: context.storage)
        // Same scoped storage as preferences; owned here so the layout (and its @Published
        // changes) outlives individual overlay sessions and drives grid re-renders.
        let layoutStore = LaunchpadLayoutStore(storage: context.storage)
        self.preferences = preferences
        self.layoutStore = layoutStore
        self.overlay = LaunchpadOverlayController(
            preferences: preferences,
            layoutStore: layoutStore,
            localization: localization
        )

        hotCornerMonitor.onTrigger = { [weak self] in self?.openLaunchpad() }
        // Apply the saved corner now and whenever the user changes it in settings.
        preferences.$hotCorner
            .sink { [weak hotCornerMonitor] corner in hotCornerMonitor?.update(corner: corner) }
            .store(in: &cancellables)
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [preferences, layoutStore, localization] _ in
            LaunchpadSettingsView(preferences: preferences, layoutStore: layoutStore, localization: localization)
        }
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

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: ShortcutID.toggle,
                title: localization.string("shortcut.toggle.title", defaultValue: "打开启动台"),
                description: localization.string(
                    "shortcut.toggle.description",
                    defaultValue: "全局快捷键唤出或收起应用网格。默认未设置，可在此自定义。"
                ),
                actionID: ActionID.toggle,
                scope: .global,
                defaultBinding: nil,        // v1: do not claim system or user hotkeys by default.
                isRequired: false
            )
        ]
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == ControlID.execute else {
            return
        }
        openLaunchpad()
    }

    func handleShortcutAction(id: String) {
        guard id == ActionID.toggle else { return }
        openLaunchpad()
    }

    private func openLaunchpad() {
        overlay.toggle()
    }

    func activate(context: PluginRuntimeContext) {
        // Resume after a pause, such as re-enabling the plugin after hiding or disabling it:
        // `deactivate` stopped the cursor poll but
        // the corner preference kept its value, so the `$hotCorner` sink (fires on CHANGE) never
        // re-arms it — re-apply explicitly here.
        hotCornerMonitor.update(corner: preferences.hotCorner)
        // Warm the app catalog in the background now, so the first summon shows
        // icons at once instead of waiting for the disk scan on the hot path.
        overlay.prewarm()
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            hotCornerMonitor.stop()      // stop the cursor poll; no runaway timer
            overlay.close()
        }
    }
}
