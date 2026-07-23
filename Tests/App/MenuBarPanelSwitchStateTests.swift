import XCTest
@testable import MacTools

final class MenuBarPanelSwitchStateTests: XCTestCase {
    func testResolveForwardsRequestedValueAndKeepsAcceptedResult() {
        var state = MenuBarPanelSwitchState(value: false)
        var handledValues: [Bool] = []

        state.resolve(requestedValue: true) { requestedValue in
            handledValues.append(requestedValue)
            return requestedValue
        }

        XCTAssertEqual(handledValues, [true])
        XCTAssertTrue(state.value)
    }

    func testResolveUsesAuthoritativeValueWhenChangeIsRejected() {
        var state = MenuBarPanelSwitchState(value: false)

        state.resolve(requestedValue: true) { _ in false }

        XCTAssertFalse(state.value)
    }

    func testSynchronizeAppliesExternalStateChanges() {
        var state = MenuBarPanelSwitchState(value: false)

        state.synchronize(with: true)

        XCTAssertTrue(state.value)
    }
}
