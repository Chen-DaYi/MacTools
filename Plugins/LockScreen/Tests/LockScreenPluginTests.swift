import XCTest
import MacToolsPluginKit
@testable import LockScreenPlugin

@MainActor
final class LockScreenPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.metadata.id, "lock-screen")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.commandDefinitions.count, 1)
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["execute"])
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
    }
}
