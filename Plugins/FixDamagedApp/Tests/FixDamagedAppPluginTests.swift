import XCTest
@testable import FixDamagedAppPlugin

@MainActor
final class FixDamagedAppPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = FixDamagedAppPlugin()

        XCTAssertEqual(plugin.metadata.id, "fix-damaged-app")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }
}
