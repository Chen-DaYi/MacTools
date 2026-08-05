import AppKit
import MacToolsPluginKit
import SwiftUI

public final class ActionGridPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ActionGridPluginProvider(context: context)
    }
}

@MainActor
private struct ActionGridPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            ActionGridPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class ActionGridPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    ActionGridHostContextConsuming,
    ActionSurfaceAssignmentSummarizing,
    PluginPortablePreferencesProviding
{
    static let showActionKey = ActionKey(providerID: "action-grid", actionID: "show")

    let metadata: PluginMetadata

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionGridHostContext: ActionGridHostContext? {
        didSet {
            if let actionGridHostContext {
                _ = store.migrate(using: actionGridHostContext)
            }
        }
    }

    let store: ActionGridStore
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.store = ActionGridStore(storage: context.storage)
        self.metadata = PluginMetadata(
            id: "action-grid",
            title: localization.string("metadata.title", defaultValue: "操作网格"),
            iconName: "square.grid.3x3",
            iconTint: Color(nsColor: .systemTeal),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "在指针附近打开常用操作网格"
            )
        )
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(
            description: localization.string(
                "metadata.description",
                defaultValue: "在指针附近打开常用操作网格"
            ),
            prefersFullHeight: true
        ) { [weak self] _ in
            if let self {
                ActionGridSettingsView(plugin: self, store: self.store)
            } else {
                EmptyView()
            }
        }
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: Self.showActionKey,
                title: localization.string(
                    "action.show.title",
                    defaultValue: "显示操作网格"
                ),
                description: localization.string(
                    "action.show.description",
                    defaultValue: "在指针附近打开操作网格。"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "操作网格"),
                    localization.string("action.show.title", defaultValue: "显示操作网格"),
                    "action",
                    "grid",
                    "launcher",
                ],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive],
                executionTimeoutSeconds: nil
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == Self.showActionKey else {
            return .unavailable(localized("操作不可用。"))
        }
        guard store.entries.contains(where: { $0.reference.key != Self.showActionKey }) else {
            return .unavailable(localized("请先配置操作网格。"))
        }
        guard actionGridHostContext?.canPresent == true else {
            return .unavailable(localized("操作网格暂时无法显示。"))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self, let context = self.actionGridHostContext else {
                return .failed(
                    message: self?.localized("操作网格暂时无法显示。")
                        ?? PluginKitLocalization.actionUnavailable
                )
            }
            let entries = self.store.entries
                .filter { $0.reference.key != Self.showActionKey }
                .map(\.presentationEntry)
            guard !entries.isEmpty, context.present(entries: entries) else {
                return .failed(message: self.localized("无法显示操作网格。"))
            }
            return .succeeded()
        }
    }

    func actionSurfaceCatalogDidChange() {
        guard let actionGridHostContext else { return }
        if store.migrate(using: actionGridHostContext) {
            onStateChange?()
        }
    }

    func makePortablePreferencesBackup() -> Data? {
        store.portableBackup()
    }

    func restorePortablePreferences(from data: Data) {
        if store.restorePortableBackup(data) {
            onStateChange?()
        }
    }

    func catalogItems(excluding entryID: UUID? = nil) -> [ActionSurfaceCatalogItem] {
        actionGridHostContext?.catalog.filter { item in
            guard item.reference.key != Self.showActionKey else { return false }
            return !store.entries.contains { entry in
                entry.id != entryID && entry.reference == item.reference
            }
        } ?? []
    }

    func item(for reference: ActionReference) -> ActionSurfaceCatalogItem? {
        actionGridHostContext?.item(for: reference)
    }

    @discardableResult
    func openOwner(for reference: ActionReference) -> Bool {
        actionGridHostContext?.openOwner(for: reference) ?? false
    }

    func suggestedReferences() -> [ActionReference] {
        let items = catalogItems()
        let priorities = [
            ActionKey(providerID: "lock-screen", actionID: "execute"),
            ActionKey(providerID: "display-sleep", actionID: "execute"),
            ActionKey(providerID: "microphone-mute", actionID: "set-enabled"),
            ActionKey(providerID: "launchpad", actionID: "toggleLaunchpad"),
        ]
        var result = priorities.compactMap { key in items.first { $0.reference.key == key }?.reference }
        let selected = Set(result)
        result.append(contentsOf: items.lazy.filter { $0.isSafe && !selected.contains($0.reference) }.map(\.reference))
        return Array(result.prefix(6))
    }

    func actionSurfaceAssignmentSummary(
        for reference: ActionReference
    ) -> ActionSurfaceAssignmentSummary? {
        guard let index = store.entries.firstIndex(where: { $0.reference == reference }) else {
            return nil
        }
        return ActionSurfaceAssignmentSummary(
            surfaceID: metadata.id,
            surfaceTitle: localization.string("metadata.title", defaultValue: "操作网格"),
            systemImage: metadata.iconName,
            detail: localizedFormat("第 %d 个条目", index + 1)
        )
    }

    func localized(_ source: String) -> String {
        localization.string(source, defaultValue: source)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(source),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    var accessibilityCopy: ActionGridAccessibilityCopy {
        ActionGridAccessibilityCopy(
            summaryFormat: localized("%@，%@，%@"),
            settingsLabelFormat: localized("设置“%@”"),
            replaceLabelFormat: localized("替换“%@”"),
            removeLabelFormat: localized("移除“%@”"),
            settingsButtonTitle: localized("设置"),
            replacementMenuTitle: localized("替换"),
            settingsHelp: localized("打开操作提供者设置"),
            replaceHelp: localized("选择其他操作替换此条目"),
            removeHelp: localized("从操作网格移除此条目")
        )
    }

    func notifyMutation() {
        onStateChange?()
    }
}
