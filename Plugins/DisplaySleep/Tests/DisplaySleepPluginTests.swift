import XCTest
@testable import DisplaySleepPlugin

@MainActor
final class DisplaySleepPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.metadata.id, "display-sleep")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.commandDefinitions.count, 1)
    }
}
