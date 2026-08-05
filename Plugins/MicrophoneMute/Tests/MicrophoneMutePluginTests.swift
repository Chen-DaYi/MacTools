import XCTest
import MacToolsPluginKit
@testable import MicrophoneMutePlugin

@MainActor
final class MicrophoneMutePluginTests: XCTestCase {
    private struct MockController: MicrophoneControlling {
        var muteState: Bool
        var setMuteResult = true

        func readMuteState() -> Bool { muteState }
        func setMuteState(_ muted: Bool) -> Bool { setMuteResult }
    }

    func testPanelStateReflectsMuteState() {
        let unmuted = MicrophoneMutePlugin(controller: MockController(muteState: false))
        let muted = MicrophoneMutePlugin(controller: MockController(muteState: true))

        XCTAssertFalse(unmuted.primaryPanelState.isOn)
        XCTAssertEqual(unmuted.primaryPanelState.subtitle, "未静音")
        XCTAssertTrue(muted.primaryPanelState.isOn)
        XCTAssertEqual(muted.primaryPanelState.subtitle, "已静音")
    }

    func testSwitchUpdatesStateAndNotifiesHost() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(notificationCount, 1)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = MicrophoneMutePlugin(
            controller: MockController(muteState: false, setMuteResult: false)
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testActionCatalogProvidesIdempotentMuteChoicesAndRunLinkConfirmation() async throws {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["麦克风静音", "恢复麦克风"])
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }
}
