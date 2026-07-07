import XCTest
@testable import AutoHideMenuBarPlugin

@MainActor
final class AutoHideMenuBarPluginTests: XCTestCase {
    func testMetadataIdentifiesAutoHideMenuBarPlugin() {
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { false }
        )

        XCTAssertEqual(plugin.metadata.id, "auto-hide-menu-bar")
        XCTAssertEqual(plugin.metadata.title, "自动隐藏菜单栏")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .switch)
    }

    func testInitialStateReflectsStateReader() {
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { true }
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchOnUpdatesMenuBarState() {
        let runner = MockMenuBarCommandRunner()
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.setMenuBarAutohideCalls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsPreviousStateAndSetsError() {
        let runner = MockMenuBarCommandRunner()
        runner.shouldFailSet = true
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testRefreshUpdatesStateWhenChangedExternally() {
        var externalState = false
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { externalState }
        )

        XCTAssertFalse(plugin.primaryPanelState.isOn)

        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }

        externalState = true
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(stateChangeCount, 1)
    }

    func testStateReaderUsesGlobalMenuBarAutohideKey() {
        let isEnabled = AutoHideMenuBarPlugin.resolvedMenuBarAutohideState(
            globalValue: true,
            dockValue: false
        )

        XCTAssertTrue(isEnabled)
    }

    func testStateReaderFallsBackToLegacyDockKey() {
        let isEnabled = AutoHideMenuBarPlugin.resolvedMenuBarAutohideState(
            globalValue: nil,
            dockValue: true
        )

        XCTAssertTrue(isEnabled)
    }
}

final class MockMenuBarCommandRunner: MenuBarCommandRunning {
    var shouldFailSet = false
    var setMenuBarAutohideCalls: [Bool] = []

    func setMenuBarAutohide(_ isEnabled: Bool) throws {
        if shouldFailSet {
            throw NSError(
                domain: "AutoHideMenuBarPluginTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "set failed"]
            )
        }

        setMenuBarAutohideCalls.append(isEnabled)
    }
}
