import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

public final class AppleShortcutsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppleShortcutsPluginProvider(context: context)
    }
}

@MainActor
private struct AppleShortcutsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AppleShortcutsPlugin(context: context)]
    }
}

@MainActor
final class AppleShortcutsPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding,
    PluginActionSafetyStateChangeProviding
{
    let metadata: PluginMetadata
    let store: AppleShortcutsStore
    let controller: AppleShortcutsController

    var onStateChange: (() -> Void)?
    var onActionSafetyStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let beforeActionRegistration: (@MainActor () async -> Void)?

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil,
        runner: (any AppleShortcutsCommandRunning)? = nil,
        now: @escaping () -> Date = { .now },
        beforeActionRegistration: (@MainActor () async -> Void)? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        let store = AppleShortcutsStore(storage: context.storage)
        self.localization = localization
        self.beforeActionRegistration = beforeActionRegistration
        self.store = store
        self.controller = AppleShortcutsController(
            store: store,
            runner: runner ?? ProcessAppleShortcutsCommandRunner(),
            localization: localization,
            now: now
        )
        self.metadata = PluginMetadata(
            id: "apple-shortcuts",
            title: localization.string("metadata.title", defaultValue: "Apple 快捷指令"),
            iconName: "square.stack.3d.up.fill",
            iconTint: Color(nsColor: .systemPurple),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "发现并运行现有的 Apple 快捷指令"
            )
        )
        controller.onStateChange = { [weak self] in self?.onStateChange?() }
        store.onSafetyPolicyMutation = { [weak self] in self?.onActionSafetyStateChange?() }
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(
            description: localization.string(
                "metadata.description",
                defaultValue: "发现并运行现有的 Apple 快捷指令"
            ),
            scrolling: .selfManaged
        ) { [weak self] _ in
            if let self {
                AppleShortcutsSettingsView(plugin: self)
            } else {
                EmptyView()
            }
        }
        .onVisibilityChange { [weak self] visible in
            if visible { self?.controller.refreshIfNeeded() }
        }
    }

    var actionDefinitions: [ActionDefinition] {
        store.trackedRecords.map { record in
            let policy = store.policy(for: record.id)
            let title = displayName(for: record)
            let needsConfirmation = policy.requiresConfirmation || policy.allowsRunLink
            return ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: record.actionID),
                title: title,
                description: localization.format(
                    "action.description.format",
                    defaultValue: "运行 Apple 快捷指令“%@”。",
                    title
                ),
                keywords: actionKeywords(for: record, title: title),
                systemImage: "square.stack.3d.up.fill",
                risk: policy.requiresConfirmation ? .confirmationRequired : .safe,
                confirmation: needsConfirmation ? ActionConfirmation(
                    title: localization.format(
                        "action.confirm.title.format",
                        defaultValue: "运行“%@”？",
                        title
                    ),
                    message: localization.string(
                        "action.confirm.message",
                        defaultValue: "此快捷指令将通过 Apple“快捷指令”运行，并可能访问其他应用或数据。"
                    ),
                    confirmButtonTitle: localization.string(
                        "action.confirm.button",
                        defaultValue: "运行"
                    )
                ) : nil,
                externalInvocationPolicy: policy.allowsRunLink ? .confirmAlways : .unavailable,
                capabilities: [.background, .foregroundInteractive, .cancellable],
                executionTimeoutSeconds: ProcessAppleShortcutsCommandRunner.runTimeout
                    + ProcessAppleShortcutsCommandRunner.actionExecutionTimeoutGraceSeconds
            )
        }
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        store.trackedRecords.map { record in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: record.actionID)
                ),
                title: displayName(for: record),
                subtitle: localization.string("action.subtitle", defaultValue: "Apple 快捷指令"),
                presentationState: controller.isRunning(record.id) ? .active : .inactive
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard let record = record(for: reference) else {
            return .unavailable(localization.string(
                "action.unavailable.untracked",
                defaultValue: "此快捷指令未启用。"
            ))
        }
        guard controller.isExecutableAvailable else {
            return .unavailable(localization.string(
                "action.unavailable.executable",
                defaultValue: "系统未提供“快捷指令”命令。"
            ))
        }
        guard controller.snapshot.shortcutIDs.contains(record.id) else {
            return .unavailable(localization.string(
                "action.unavailable.missing",
                defaultValue: "在 Apple“快捷指令”中找不到此项目。"
            ))
        }
        guard !controller.isRunning(record.id) else {
            return .unavailable(localization.string(
                "action.unavailable.running",
                defaultValue: "此快捷指令正在运行。"
            ))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let record = record(for: invocation.reference),
              controller.snapshot.shortcutIDs.contains(record.id) else {
            return ActionExecutionHandle { [localization] in
                .failed(message: localization.string(
                    "action.unavailable.missing",
                    defaultValue: "在 Apple“快捷指令”中找不到此项目。"
                ))
            }
        }
        return ActionExecutionHandle { [weak self] in
            guard !Task.isCancelled else { return .cancelled }
            guard let self else { return .cancelled }
            if let beforeActionRegistration = self.beforeActionRegistration {
                await beforeActionRegistration()
            }
            guard !Task.isCancelled else { return .cancelled }
            let startResult = controller.startExecution(
                shortcutID: record.id,
                name: displayName(for: record)
            )
            switch startResult {
            case let .success(run):
                return await controller.waitForExecution(run, shortcutID: record.id)
            case .failure(.cancelled):
                return .cancelled
            case let .failure(error):
                return .failed(message: controller.executionStartMessage(for: error))
            }
        } cancel: { [weak self] in
            self?.controller.cancelExecution(shortcutID: record.id)
        }
    }

    func activate(context _: PluginRuntimeContext) { controller.activate() }
    func refresh() { controller.refreshIfNeeded() }
    func deactivate(reason _: PluginDeactivationReason) { controller.deactivate() }

    func makePortablePreferencesBackup() -> Data? { store.portableBackup() }
    func restorePortablePreferences(from data: Data) { _ = store.restorePortableBackup(data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        store.restorePortableBackup(data)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        store.actionIDs(inPortableBackup: data)?.map {
            ActionReference(key: ActionKey(providerID: metadata.id, actionID: $0))
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        record(for: reference) == nil ? .excluded : .requiresPluginPreferences
    }

    func item(id: UUID) -> AppleShortcutItem? {
        controller.snapshot.discovery.shortcuts.first { $0.id == id }
    }

    func folder(id: UUID) -> AppleShortcutFolder? {
        controller.snapshot.discovery.folders.first { $0.id == id }
    }

    func displayName(for record: AppleShortcutTrackedRecord) -> String {
        item(id: record.id)?.name
            ?? record.lastKnownName.appleShortcutsNilIfEmpty
            ?? localization.string("shortcut.unknown", defaultValue: "未找到的快捷指令")
    }

    func localized(_ key: String, defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }

    func localizedFormat(_ key: String, defaultValue: String, _ argument: CVarArg) -> String {
        localization.format(key, defaultValue: defaultValue, argument)
    }

    func localizedFormat(
        _ key: String,
        defaultValue: String,
        _ firstArgument: CVarArg,
        _ secondArgument: CVarArg
    ) -> String {
        localization.format(
            key,
            defaultValue: defaultValue,
            firstArgument,
            secondArgument
        )
    }

    private func record(for reference: ActionReference) -> AppleShortcutTrackedRecord? {
        guard reference.key.providerID == metadata.id,
              reference.schemaVersion == 1,
              reference.parameters.entries.isEmpty,
              let id = AppleShortcutsStore.shortcutID(fromActionID: reference.key.actionID),
              store.isEnabled(id) else { return nil }
        return store.record(id: id)
    }

    private func actionKeywords(
        for record: AppleShortcutTrackedRecord,
        title: String
    ) -> [String] {
        let folderNames = record.lastKnownFolderIDs.compactMap { id in
            folder(id: id)?.name ?? store.state.syncedFolders[id]?.lastKnownName
        }
        return [metadata.title, title, "Apple", "Shortcuts", "快捷指令"] + folderNames
    }
}
