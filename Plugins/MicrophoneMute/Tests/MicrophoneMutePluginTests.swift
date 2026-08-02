import XCTest
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
}
