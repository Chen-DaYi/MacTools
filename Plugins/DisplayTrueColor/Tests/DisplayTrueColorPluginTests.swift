import XCTest
@testable import DisplayTrueColorPlugin

@MainActor
final class DisplayTrueColorPluginTests: XCTestCase {
    func testPanelStateReflectsSupportedAndUnsupportedDisplays() {
        let enabled = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: true, isEnabled: true)
        )
        let unsupported = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: false, isEnabled: nil)
        )

        XCTAssertTrue(enabled.primaryPanelState.isOn)
        XCTAssertTrue(enabled.primaryPanelState.isEnabled)
        XCTAssertFalse(unsupported.primaryPanelState.isOn)
        XCTAssertFalse(unsupported.primaryPanelState.isEnabled)
        XCTAssertEqual(unsupported.primaryPanelState.subtitle, "不支持")
    }

    func testSwitchUpdatesClientAndPanelState() {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(client.lastSetEnabled, true)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testSwitchIsIgnoredWhenUnsupported() {
        let client = MockTrueToneClient(isSupported: false, isEnabled: nil)
        let plugin = DisplayTrueColorPlugin(client: client)

        plugin.handleAction(.setSwitch(true))

        XCTAssertNil(client.lastSetEnabled)
    }

    func testRefreshReadsExternalState() {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)

        client.stubbedEnabled = true
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }
}

@MainActor
private final class MockTrueToneClient: TrueToneClient {
    private let supported: Bool
    var stubbedEnabled: Bool?
    private(set) var lastSetEnabled: Bool?

    init(isSupported: Bool, isEnabled: Bool?) {
        supported = isSupported
        stubbedEnabled = isEnabled
    }

    var isSupported: Bool { supported }
    var isEnabled: Bool? { stubbedEnabled }

    func setEnabled(_ enabled: Bool) {
        stubbedEnabled = enabled
        lastSetEnabled = enabled
    }
}
