import XCTest
import MacToolsPluginKit
@testable import AppearancePlugin

@MainActor
final class AppearancePluginTests: XCTestCase {
    func testPublishesIdempotentLightAndDarkActions() {
        let plugin = AppearancePlugin()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), [
            "启用深色模式",
            "启用浅色模式",
        ])
        XCTAssertTrue(
            plugin.actionDefinitions[0].capabilities.contains(.background)
        )
        XCTAssertEqual(
            plugin.actionDefinitions[0].externalInvocationPolicy,
            .allowed
        )
    }
}
