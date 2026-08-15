import XCTest
import MacToolsPluginKit
@testable import LaunchpadPlugin

@MainActor
final class LaunchpadPluginActionTests: XCTestCase {
    func testPublishesForegroundActionAndLegacyShortcutMigration() throws {
        let plugin = LaunchpadPlugin(
            context: PluginRuntimeContext(
                pluginID: "launchpad",
                storage: FakePluginStorage()
            )
        )
        plugin.shortcutBindingResolver = { shortcutID in
            guard shortcutID == "launchpad.toggle" else { return nil }
            return ShortcutBinding(keyCode: 40, modifiers: [.command, .option])
        }

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggleLaunchpad"])
        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["打开启动台"])
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments.first?.legacyShortcutDefinitionID,
            "launchpad.toggle"
        )
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments.first?.reference,
            plugin.actionCatalogEntries.first?.reference
        )
    }
}
