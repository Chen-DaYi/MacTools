import XCTest
@testable import MacTools

@MainActor
final class AutomationStartupCoordinatorTests: XCTestCase {
    func testTriggerSourceDoesNotStartDuringDelayedActionRegistryPreparation() async {
        var triggerHandler: (() -> Void)?
        var startCount = 0
        var handledEventCount = 0
        var preparationContinuation: CheckedContinuation<Void, Never>?
        let coordinator = AutomationStartupCoordinator {
            startCount += 1
            triggerHandler = { handledEventCount += 1 }
        }

        let preparation = Task { @MainActor in
            await coordinator.startAfterActionRegistryPreparation {
                await withCheckedContinuation { continuation in
                    preparationContinuation = continuation
                }
            }
        }
        for _ in 0 ..< 100 where preparationContinuation == nil {
            await Task.yield()
        }

        XCTAssertTrue(coordinator.isPreparing)
        triggerHandler?()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(handledEventCount, 0)

        preparationContinuation?.resume()
        await preparation.value
        triggerHandler?()
        coordinator.actionRegistryDidBecomeReady()

        XCTAssertTrue(coordinator.hasStarted)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(handledEventCount, 1)
    }
}
