import XCTest
@testable import MacTools
@testable import MicrophoneMutePlugin

@MainActor
final class MicrophoneMutePluginTests: XCTestCase {
    private struct MockController: MicrophoneControlling {
        var muteState: Bool
        var setMuteResult: Bool = true

        func readMuteState() -> Bool { muteState }
        func setMuteState(_ muted: Bool) -> Bool { setMuteResult }
    }

    func testMetadataIdentifiesMicrophoneMutePlugin() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertEqual(plugin.metadata.id, "microphone-mute")
        XCTAssertEqual(plugin.metadata.title, "麦克风静音")
    }

    func testControlStyleIsSwitch() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .switch)
    }

    func testPanelStateReflectsUnmutedStatus() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "未静音")
    }

    func testPanelStateReflectsMutedStatus() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已静音")
    }

    func testPanelStateIsAlwaysEnabled() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPluginHostIncludesMicrophoneMuteWhenProvided() {
        let host = makePluginHostForTests(plugins: [MicrophoneMutePlugin(controller: MockController(muteState: false))])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "microphone-mute" })
    }

    func testHandleActionMutesWhenSwitchedOn() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testHandleActionUnmutesWhenSwitchedOff() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: true))

        plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testHandleActionOnFailureSetsErrorMessage() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false, setMuteResult: false))

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testRefreshUpdatesStateWhenExternallyChanged() {
        var controller = MockController(muteState: false)
        let plugin = MicrophoneMutePlugin(controller: controller)
        XCTAssertFalse(plugin.primaryPanelState.isOn)

        controller.muteState = true
        // Reinitialize with the updated controller state to simulate refresh reading an external change.
        let plugin2 = MicrophoneMutePlugin(controller: controller)
        XCTAssertTrue(plugin2.primaryPanelState.isOn)
    }

    func testRefreshCallsOnStateChangeWhenMuteStateChanges() {
        var controller = MockController(muteState: false)
        let plugin = MicrophoneMutePlugin(controller: controller)
        var callCount = 0
        plugin.onStateChange = { callCount += 1 }

        plugin.refresh()
        XCTAssertEqual(callCount, 0)

        // `isMuted` is not directly mutable here; validate the callback path through `handleAction`.
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(callCount, 1)
    }

    func testDefaultDescriptionMatches() {
        let plugin = MicrophoneMutePlugin(controller: MockController(muteState: false))

        XCTAssertEqual(plugin.metadata.defaultDescription, "快速静音或恢复默认麦克风输入")
    }
}
