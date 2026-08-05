import XCTest
import MacToolsPluginKit
@testable import NightShiftPlugin

@MainActor
final class NightShiftPluginTests: XCTestCase {
    private struct MockController: NightShiftControlling {
        var status: Bool
        var setEnabledResult = true

        func getStatus() -> Bool { status }
        func setEnabled(_ enabled: Bool) -> Bool { setEnabledResult }
    }

    func testPanelStateReflectsControllerStatus() {
        let disabled = NightShiftPlugin(controller: MockController(status: false))
        let enabled = NightShiftPlugin(controller: MockController(status: true))

        XCTAssertFalse(disabled.primaryPanelState.isOn)
        XCTAssertEqual(disabled.primaryPanelState.subtitle, "已关闭")
        XCTAssertTrue(enabled.primaryPanelState.isOn)
        XCTAssertEqual(enabled.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchUpdatesPanelState() {
        let plugin = NightShiftPlugin(controller: MockController(status: false))

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = NightShiftPlugin(
            controller: MockController(status: true, setEnabledResult: false)
        )

        plugin.handleAction(.setSwitch(false))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testActionCatalogProvidesIdempotentNightShiftChoices() async throws {
        let plugin = NightShiftPlugin(controller: MockController(status: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["启用夜览", "停用夜览"])
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }
}
