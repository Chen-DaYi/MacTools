import XCTest
import MacToolsPluginKit
@testable import MenuBarHiddenPlugin

@MainActor
final class MenuBarHiddenPluginTests: XCTestCase {
    func testActionCatalogPublishesEnabledAndDisabledChoices() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled"))
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(definition.capabilities.contains(.background))
        XCTAssertEqual(plugin.actionCatalogEntries.count, 2)
        XCTAssertEqual(
            plugin.actionCatalogEntries.compactMap { $0.reference.parameters["enabled"] },
            [.boolean(true), .boolean(false)]
        )
    }

    func testActionRejectsMissingAndInvalidParameters() async throws {
        let plugin = makePlugin()
        let missing = ActionReference(
            key: ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled")
        )
        let invalid = ActionReference(
            key: ActionKey(providerID: "menu-bar-hidden", actionID: "set-enabled"),
            parameters: try ActionParameterSet(["enabled": .string("yes")])
        )

        for reference in [missing, invalid] {
            let result = try await plugin.beginAction(
                ActionInvocation(reference: reference, source: .test, mode: .background)
            ).result()
            guard case .failed = result else {
                return XCTFail("Expected invalid parameters to fail")
            }
        }
    }

    func testActionsAreIdempotentWithoutActivatingTheMenuBarController() async throws {
        let plugin = makePlugin()
        let enabled = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let disabled = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        for reference in [enabled, enabled, disabled, disabled] {
            let result = try await plugin.beginAction(
                ActionInvocation(reference: reference, source: .test, mode: .background)
            ).result()
            XCTAssertEqual(result, .succeeded())
        }

        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    private func makePlugin() -> MenuBarHiddenPlugin {
        MenuBarHiddenPlugin(
            context: PluginRuntimeContext(
                pluginID: "menu-bar-hidden",
                storage: MenuBarHiddenTestStorage()
            )
        )
    }
}

@MainActor
private final class MenuBarHiddenTestStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
