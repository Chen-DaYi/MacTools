import XCTest
import MacToolsPluginKit
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

    func testCanonicalActionUsesTheTrueToneClient() async throws {
        let client = MockTrueToneClient(isSupported: true, isEnabled: false)
        let plugin = DisplayTrueColorPlugin(client: client)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(client.lastSetEnabled, true)
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
    }

    func testCanonicalActionIsUnavailableOnUnsupportedHardware() throws {
        let plugin = DisplayTrueColorPlugin(
            client: MockTrueToneClient(isSupported: false, isEnabled: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
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
