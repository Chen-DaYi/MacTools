import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class AppHotkeyPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppHotkeyPluginProvider(context: context)
    }
}

@MainActor
private struct AppHotkeyPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [AppHotkeyPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class AppHotkeyPlugin: MacToolsPlugin, PluginPrimaryPanel {

    // MARK: Metadata

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private

    private let store: AppHotkeyStore
    private let hotkeyManager: AppHotkeyManager
    private let storage: PluginStorage
    private let localization: PluginLocalization
    private var isEnabled: Bool

    // MARK: Init

    init(context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "app-hotkey")) {
        self.localization = PluginLocalization(bundle: context.resourceBundle)
        self.storage = context.storage
        self.store = AppHotkeyStore(storage: context.storage)
        self.hotkeyManager = AppHotkeyManager()
        self.metadata = PluginMetadata(
            id: "app-hotkey",
            title: localization.string("metadata.title", defaultValue: "应用快捷键"),
            iconName: "keyboard",
            iconTint: Color(nsColor: .systemYellow),
            order: 65,
            defaultDescription: localization.string("metadata.description", defaultValue: "为常用应用绑定全局快捷键")
        )
        // Enabled by default; only an explicit user pause stores `false`.
        self.isEnabled = context.storage.object(forKey: "isEnabled") == nil
            ? true
            : context.storage.bool(forKey: "isEnabled")

        hotkeyManager.onTrigger = { [weak self] id in
            self?.launch(entryID: id)
        }
    }

    // MARK: MacToolsPlugin

    func activate(context: PluginRuntimeContext) {
        syncHotkeys()
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            hotkeyManager.unregisterAll()
        }
    }

    func refresh() {}

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    // Hotkeys are managed by this plugin instead of the host shortcut system.
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [self] _ in
            AppHotkeyManagerView(
                store: self.store,
                localization: self.localization,
                onUpdate: { [weak self] in
                    self?.syncHotkeys()
                    self?.onStateChange?()
                },
                onBeginRecording: { [weak self] id in
                    self?.hotkeyManager.temporarilyDisable(id: id)
                },
                onEndRecording: { [weak self] _ in
                    self?.syncHotkeys()
                }
            )
        }
    }

    // MARK: PluginPrimaryPanel

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(value):
            isEnabled = value
            storage.set(value, forKey: "isEnabled")
            syncHotkeys()
            onStateChange?()
        default:
            break
        }
    }

    // MARK: Private

    private var panelSubtitle: String {
        let count = store.entries.filter { $0.shortcut != nil }.count
        guard count > 0 else {
            return localization.string("panel.subtitle.empty", defaultValue: "暂无绑定，前往设置配置")
        }
        return isEnabled
            ? localization.format("panel.subtitle.enabledCountFormat", defaultValue: "%d 个快捷键已启用", count)
            : localization.string("panel.subtitle.paused", defaultValue: "快捷键已暂停")
    }

    private func syncHotkeys() {
        hotkeyManager.sync(entries: isEnabled ? store.entries : [])
    }

    /// Hides the target app when it is frontmost; otherwise opens or activates it.
    private func launch(entryID: UUID) {
        guard let entry = store.entries.first(where: { $0.id == entryID }),
              let bundleURL = entry.bundleURL
        else { return }

        let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier

        if let bundleIdentifier,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == bundleIdentifier {
            frontmost.hide()
        } else {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        }
    }
}
