import XCTest
import MacToolsPluginKit
@testable import PhysicalCleanModePlugin

@MainActor
final class PhysicalCleanModePluginTests: XCTestCase {
    func testCanonicalEnterActionIsGuardedAndForegroundOnly() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { false },
            accessibilityRequester: { _ in false }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.key.actionID, "enter")
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            ["accessibility"]
        )
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    func testCanonicalEnterActionRequiresAValidEmergencyExitShortcut() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { true },
            accessibilityRequester: { _ in true }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        plugin.shortcutBindingResolver = { id in
            guard id == "exit-physical-clean-mode" else { return nil }
            return ShortcutBinding(keyCode: 53, modifiers: [.control, .command])
        }

        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)
    }
}
