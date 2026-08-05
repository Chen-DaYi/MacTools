import Carbon
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostActionRegistryTests: XCTestCase {
    func testHostPublishesNativeLegacyAndApplicationActionsThroughOneRegistry() async {
        let native = NativeActionTestPlugin()
        let legacy = LegacyActionTestPlugin()
        let host = makePluginHostForTests(plugins: [native, legacy])
        var presentationRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { presentationRequests.append($0) }

        let catalogKeys = Set(host.actionCatalogEntries.map(\.reference.key))
        XCTAssertTrue(catalogKeys.contains(native.definition.key))
        XCTAssertTrue(
            catalogKeys.contains(ActionKey(providerID: legacy.metadata.id, actionID: "sleep"))
        )
        XCTAssertTrue(
            catalogKeys.contains(
                ActionKey(
                    providerID: "mactools",
                    actionID: AppShortcutAction.openSettings.rawValue
                )
            )
        )

        let nativeOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: native.definition.key),
                source: .test,
                mode: .background
            )
        )
        XCTAssertEqual(nativeOutcome, .completed(.succeeded(message: "native")))
        XCTAssertEqual(native.beginCount, 1)

        let legacyOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(
                    key: ActionKey(providerID: legacy.metadata.id, actionID: "sleep")
                ),
                source: .test,
                mode: .background
            )
        )
        XCTAssertEqual(legacyOutcome, .completed(.succeeded()))
        XCTAssertEqual(legacy.performedCommandIDs, ["sleep"])

        let appOutcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(
                    key: ActionKey(
                        providerID: "mactools",
                        actionID: AppShortcutAction.openSettings.rawValue
                    )
                ),
                source: .test,
                mode: .foreground
            )
        )
        XCTAssertEqual(appOutcome, .completed(.succeeded()))
        XCTAssertEqual(presentationRequests, [.settings(.settings)])
    }

    func testNativeProviderAvailabilityIsEvaluatedAtExecutionTime() async {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.availability = .unavailable("目标已断开连接")

        let outcome = await host.actionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: plugin.definition.key),
                source: .test,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.unavailable("目标已断开连接")))
        XCTAssertEqual(plugin.beginCount, 0)
    }

    func testActionOwnerNavigationUsesHostSettingsRoutes() {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        XCTAssertTrue(
            host.presentActionOwner(
                for: ActionReference(key: ActionKey(providerID: "mactools", actionID: "test"))
            )
        )
        XCTAssertTrue(
            host.presentActionOwner(
                for: ActionReference(
                    key: ActionKey(providerID: AutomationController.providerID, actionID: "test")
                )
            )
        )
        XCTAssertFalse(
            host.presentActionOwner(
                for: ActionReference(key: ActionKey(providerID: "missing", actionID: "test"))
            )
        )
        XCTAssertEqual(
            requests,
            [
                .settings(.feature(.actionsAndShortcuts)),
                .settings(.feature(.automation)),
            ]
        )
    }

    func testActionShortcutSuppressesRecursiveSyntheticRetrigger() async throws {
        let registrar = FakeCarbonHotKeyRegistrar()
        let shortcutManager = GlobalShortcutManager(registrar: registrar)
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(
            plugins: [plugin],
            globalShortcutManager: shortcutManager
        )
        let reference = ActionReference(key: plugin.definition.key)
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command, .option])
        XCTAssertEqual(host.setActionShortcutBinding(binding, to: reference), .success)
        let shortcutID = try XCTUnwrap(
            shortcutManager.debugRegistrationsForTests.first(where: {
                $0.binding == binding
            })?.shortcutID
        )
        plugin.operation = {
            shortcutManager.triggerForTests(shortcutID: shortcutID)
            await Task.yield()
            return .succeeded()
        }

        shortcutManager.triggerForTests(shortcutID: shortcutID)
        for _ in 0 ..< 20 where plugin.beginCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(plugin.beginCount, 1)
    }

    func testHostAggregatesActionSurfaceAssignmentSummaries() {
        let plugin = NativeActionTestPlugin()
        plugin.summarizedReference = ActionReference(key: plugin.definition.key)
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionSurfaceAssignmentSummaries(for: plugin.summarizedReference!),
            [
                ActionSurfaceAssignmentSummary(
                    surfaceID: plugin.metadata.id,
                    surfaceTitle: plugin.metadata.title,
                    systemImage: plugin.metadata.iconName,
                    detail: "已分配"
                ),
            ]
        )
    }

    func testHostProjectsProviderOwnedActionPermissionRequirements() {
        let plugin = NativeActionTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])

        XCTAssertEqual(
            host.actionPermissionTitles(for: ActionReference(key: plugin.definition.key)),
            ["测试权限"]
        )
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: {
                $0.reference.key == plugin.definition.key
            })?.permissionSummary,
            "所需权限：测试权限"
        )
    }

    func testActionBackedPluginShortcutEditorsShareOneAssignmentAndRegistration() throws {
        let registrar = FakeCarbonHotKeyRegistrar()
        let shortcutManager = GlobalShortcutManager(registrar: registrar)
        let plugin = ActionBackedShortcutTestPlugin()
        let suiteName = "PluginHostActionRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_A),
            modifiers: [.command, .option]
        )
        let shortcutStore = ShortcutStore(userDefaults: defaults)
        shortcutStore.setCustomization(
            .custom(legacyBinding),
            for: ActionBackedShortcutTestPlugin.shortcutItemID
        )
        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: shortcutStore,
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(
                userDefaults: defaults
            ),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: shortcutManager
        )
        let reference = ActionReference(key: plugin.definition.key)

        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            legacyBinding
        )
        XCTAssertEqual(
            shortcutStore.customization(for: ActionBackedShortcutTestPlugin.shortcutItemID),
            .cleared
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.filter {
                $0.reference == reference
            }.count,
            1
        )
        XCTAssertEqual(
            try shortcutItem(in: host).bindingText,
            ShortcutFormatter.displayString(for: legacyBinding)
        )
        let initialRegistrations = registrations(
            for: reference,
            in: host,
            manager: shortcutManager
        )
        XCTAssertEqual(initialRegistrations.count, 1)
        XCTAssertTrue(initialRegistrations.first?.shortcutID.hasPrefix("action-shortcut.") ?? false)

        let pluginEditorBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_B),
            modifiers: [.command, .option]
        )
        XCTAssertNil(
            host.setShortcutBindingAndReturnError(
                pluginEditorBinding,
                for: ActionBackedShortcutTestPlugin.shortcutItemID
            )
        )
        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            pluginEditorBinding
        )
        XCTAssertEqual(
            try shortcutItem(in: host).bindingText,
            ShortcutFormatter.displayString(for: pluginEditorBinding)
        )
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)

        let centralEditorBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_N),
            modifiers: [.command, .shift]
        )
        XCTAssertEqual(
            host.setActionShortcutBinding(centralEditorBinding, to: reference),
            .success
        )
        XCTAssertEqual(
            try shortcutItem(in: host).bindingText,
            ShortcutFormatter.displayString(for: centralEditorBinding)
        )
        XCTAssertEqual(
            host.actionShortcutSettingsItem(for: reference)?.assignment.binding,
            centralEditorBinding
        )
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)

        host.clearActionShortcut(for: reference)
        XCTAssertEqual(
            try shortcutItem(in: host).bindingText,
            ShortcutFormatter.displayString(for: nil)
        )
        XCTAssertFalse(try shortcutItem(in: host).usesDefaultValue)

        host.resetShortcut(for: ActionBackedShortcutTestPlugin.shortcutItemID)
        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            plugin.defaultBinding
        )
        XCTAssertTrue(try shortcutItem(in: host).usesDefaultValue)
        XCTAssertEqual(registrations(for: reference, in: host, manager: shortcutManager).count, 1)
    }

    private func shortcutItem(in host: PluginHost) throws -> ShortcutSettingsItem {
        try XCTUnwrap(host.shortcutItems.first(where: {
            $0.id == ActionBackedShortcutTestPlugin.shortcutItemID
        }))
    }

    private func registrations(
        for reference: ActionReference,
        in host: PluginHost,
        manager: GlobalShortcutManager
    ) -> [GlobalShortcutManager.Registration] {
        guard let binding = host.actionShortcutSettingsItem(for: reference)?.assignment.binding else {
            return []
        }
        return manager.debugRegistrationsForTests.filter {
            $0.binding == binding
        }
    }
}

@MainActor
private final class NativeActionTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionPermissionProviding,
    ActionSurfaceAssignmentSummarizing
{
    let metadata = PluginMetadata(
        id: "action-provider",
        title: "操作插件",
        iconName: "bolt",
        iconTint: .blue,
        order: 1,
        defaultDescription: "测试操作"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var availability: ActionAvailability = .available
    var beginCount = 0
    var summarizedReference: ActionReference?
    var operation: @MainActor @Sendable () async -> ActionExecutionResult = {
        .succeeded(message: "native")
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "test-permission",
                kind: .accessibility,
                title: "测试权限",
                description: "测试操作所需权限"
            ),
        ]
    }

    let definition = ActionDefinition(
        key: ActionKey(providerID: "action-provider", actionID: "toggle"),
        title: "切换",
        description: "切换测试状态",
        systemImage: "bolt",
        externalInvocationPolicy: .allowed,
        capabilities: [.background, .foregroundInteractive]
    )

    var actionDefinitions: [ActionDefinition] {
        [definition]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        availability
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        beginCount += 1
        return ActionExecutionHandle(operation: operation)
    }

    func actionSurfaceAssignmentSummary(
        for reference: ActionReference
    ) -> ActionSurfaceAssignmentSummary? {
        guard reference == summarizedReference else { return nil }
        return ActionSurfaceAssignmentSummary(
            surfaceID: metadata.id,
            surfaceTitle: metadata.title,
            systemImage: metadata.iconName,
            detail: "已分配"
        )
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionKey == definition.key ? ["test-permission"] : []
    }
}

@MainActor
private final class LegacyActionTestPlugin: MacToolsPlugin, PluginCommandProviding {
    let metadata = PluginMetadata(
        id: "legacy-provider",
        title: "旧操作插件",
        iconName: "moon",
        iconTint: .gray,
        order: 2,
        defaultDescription: "测试旧操作"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var performedCommandIDs: [String] = []

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "sleep",
                title: "休眠",
                description: "立即休眠",
                systemImage: "moon"
            ),
        ]
    }

    func handleCommand(id: String) {
        performedCommandIDs.append(id)
    }
}

@MainActor
private final class ActionBackedShortcutTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginLegacyActionShortcutProviding
{
    static let shortcutItemID = "action-backed-shortcut.shortcut.toggle"

    let metadata = PluginMetadata(
        id: "action-backed-shortcut",
        title: "共享快捷键",
        iconName: "command",
        iconTint: .blue,
        order: 3,
        defaultDescription: "测试共享快捷键"
    )
    let defaultBinding = ShortcutBinding(
        keyCode: UInt16(kVK_ANSI_M),
        modifiers: [.command, .option]
    )
    let definition = ActionDefinition(
        key: ActionKey(providerID: "action-backed-shortcut", actionID: "toggle"),
        title: "切换",
        description: "切换测试状态",
        systemImage: "command",
        externalInvocationPolicy: .allowed,
        capabilities: [.foregroundInteractive]
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "toggle",
                title: "切换",
                description: "切换测试状态",
                actionID: definition.key.actionID,
                scope: .global,
                defaultBinding: defaultBinding,
                isRequired: false
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] { [definition] }

    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        guard let binding = shortcutBindingResolver?("toggle") else { return [] }
        return [
            LegacyActionShortcutAssignment(
                reference: ActionReference(key: definition.key),
                binding: binding,
                legacyShortcutDefinitionID: "toggle"
            ),
        ]
    }

    func legacyActionShortcutsDidMigrate() {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}
