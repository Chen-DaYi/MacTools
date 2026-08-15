import XCTest
import MacToolsPluginKit
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

    func testCanonicalActionUsesTheStageManagerCommand() async throws {
        let runner = MockStageManagerCommandRunner()
        let plugin = StageManagerPlugin(commandRunner: runner, stateReader: { false })
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(runner.calls, [true])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
    }

    func testCanonicalActionReportsCommandFailure() async throws {
        let plugin = StageManagerPlugin(
            commandRunner: MockStageManagerCommandRunner(shouldFail: true),
            stateReader: { false }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected a failed action result")
        }
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
