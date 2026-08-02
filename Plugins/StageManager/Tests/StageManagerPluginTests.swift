import XCTest
@testable import StageManagerPlugin

@MainActor
final class StageManagerPluginTests: XCTestCase {
    func testInitialStateReflectsStateReader() {
        let plugin = StageManagerPlugin(
            commandRunner: MockStageManagerCommandRunner(),
            stateReader: { true }
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchUpdatesStageManagerState() {
        let runner = MockStageManagerCommandRunner()
        let plugin = StageManagerPlugin(commandRunner: runner, stateReader: { false })

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.calls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let runner = MockStageManagerCommandRunner(shouldFail: true)
        let plugin = StageManagerPlugin(commandRunner: runner, stateReader: { false })

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }
}

private final class MockStageManagerCommandRunner: StageManagerCommandRunning {
    let shouldFail: Bool
    private(set) var calls: [Bool] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func setStageManagerEnabled(_ isEnabled: Bool) throws {
        if shouldFail {
            throw NSError(domain: "StageManagerPluginTests", code: 1)
        }
        calls.append(isEnabled)
    }
}
