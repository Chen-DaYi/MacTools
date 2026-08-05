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
}

@MainActor
private final class NativeActionTestPlugin: MacToolsPlugin, PluginActionProviding {
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
        return ActionExecutionHandle(operation: { .succeeded(message: "native") })
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
