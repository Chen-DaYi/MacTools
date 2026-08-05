import Foundation
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
        XCTAssertNil(plugin.componentPanel)
    }

    func testManifestPanelCapabilitiesMatchRuntimeContract() throws {
        struct Manifest: Decodable {
            struct Capabilities: Decodable {
                let primaryPanel: Bool
                let componentPanel: Bool
            }

            let capabilities: Capabilities
        }

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugin.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let plugin = FixDamagedAppPlugin()

        XCTAssertEqual(manifest.capabilities.primaryPanel, plugin.primaryPanel != nil)
        XCTAssertEqual(manifest.capabilities.componentPanel, plugin.componentPanel != nil)
    }
}
