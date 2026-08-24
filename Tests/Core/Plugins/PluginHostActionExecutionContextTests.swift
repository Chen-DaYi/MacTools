import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostActionExecutionContextTests: XCTestCase {
    func testConsumerReceivesLiveCatalogAndExecutionUsesProvider() async throws {
        let provider = HostContextActionProviderPlugin()
        let consumer = HostContextConsumerPlugin()
        let host = makePluginHostForTests(plugins: [provider, consumer])
        let context = try XCTUnwrap(consumer.actionExecutionHostContext)
        let reference = ActionReference(
            key: ActionKey(providerID: provider.metadata.id, actionID: "run")
        )

        XCTAssertEqual(context.item(for: reference)?.reference, reference)
        XCTAssertGreaterThan(consumer.catalogChangeCount, 0)
        let result = await context.execute(reference, source: .test)
        XCTAssertEqual(result, .succeeded(message: "done"))
        XCTAssertEqual(provider.executionCount, 1)
        _ = host
    }
}

@MainActor
private final class HostContextConsumerPlugin:
    MacToolsPlugin,
    PluginActionExecutionHostContextConsuming
{
    let metadata = PluginMetadata(
        id: "host-context-consumer",
        title: "Consumer",
        iconName: "arrow.triangle.branch",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Consumes actions"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionExecutionHostContext: PluginActionExecutionHostContext?
    private(set) var catalogChangeCount = 0

    func actionExecutionCatalogDidChange() {
        catalogChangeCount += 1
    }

    func refresh() {}
}

@MainActor
private final class HostContextActionProviderPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "host-context-provider",
        title: "Provider",
        iconName: "play.circle",
        iconTint: .green,
        order: 2,
        defaultDescription: "Provides an action"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var executionCount = 0

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "run"),
                title: "Run",
                description: "Run provider action",
                systemImage: "play.circle",
                externalInvocationPolicy: .allowed,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: "run")
                ),
                title: "Run"
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            self?.executionCount += 1
            return .succeeded(message: "done")
        }
    }

    func refresh() {}
}
