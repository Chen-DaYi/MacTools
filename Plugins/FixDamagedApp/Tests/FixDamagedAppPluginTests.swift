import Foundation
import XCTest
import MacToolsPluginKit
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

    func testCanonicalActionOpensTheAppChooserAsAForegroundAction() async throws {
        var chooserCallCount = 0
        let plugin = FixDamagedAppPlugin(chooseAppOverride: {
            chooserCallCount += 1
        })
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(chooserCallCount, 1)
    }
}
