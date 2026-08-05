import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridPluginTests: XCTestCase {
    func testShowActionIsForegroundOnlyExternallyEligibleAndPresentsSavedEntries() async throws {
        let storage = ActionGridTestStorage()
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: storage)
        )
        let target = ActionReference(key: ActionKey(providerID: "target", actionID: "run"))
        var presented: [ActionGridPresentationEntry] = []
        var openedOwner: ActionReference?
        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            openOwner: {
                openedOwner = $0
                return true
            },
            canPresent: { true },
            present: {
                presented = $0
                return true
            }
        )
        XCTAssertTrue(plugin.store.add(reference: target))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionGridPlugin.showActionKey)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .globalShortcut,
                mode: .foreground
            )
        )
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presented.map(\.reference), [target])
        XCTAssertTrue(plugin.openOwner(for: target))
        XCTAssertEqual(openedOwner, target)
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: target)?.detail,
            "第 1 个条目"
        )
    }

    func testShowActionIsUnavailableWithoutEntriesOrHostPresenterAndSelfEntryIsNeverPresented() async throws {
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: ActionGridTestStorage())
        )
        let showReference = ActionReference(key: ActionGridPlugin.showActionKey)
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)

        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            canPresent: { true },
            present: { _ in XCTFail("Presenter should not be called"); return false }
        )
        XCTAssertTrue(plugin.store.add(reference: showReference))
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: showReference, source: .manual, mode: .foreground)
        )
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: "无法显示操作网格。"))
    }
}
