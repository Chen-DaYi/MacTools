import XCTest
@testable import MacTools

@MainActor
final class SettingsNavigationCoordinatorTests: XCTestCase {
    func testRecordsCompletePluginDestinationsAndRestoresExactPaneDuringTraversal() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        coordinator.navigate(to: .plugins(.dashboardLayout))
        coordinator.navigate(to: .plugins(.featurePanelLayout))
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .about)

        XCTAssertEqual(
            coordinator.history,
            [
                .general,
                .plugins(.dashboardLayout),
                .plugins(.featurePanelLayout),
                .plugins(.marketplace),
                .plugins(.configuration("fan-control")),
                .about
            ]
        )

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
        XCTAssertEqual(coordinator.history.count, 6)
        XCTAssertEqual(coordinator.historyIndex, 4)
    }

    func testSuppressesConsecutiveDuplicateDestinations() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)
        coordinator.navigate(to: .about)

        XCTAssertEqual(coordinator.history, [.general, .about])
        XCTAssertEqual(coordinator.historyIndex, 1)
    }

    func testNormalNavigationAfterBackInvalidatesForwardHistory() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.goBack()
        coordinator.navigate(to: .plugins(.dashboardLayout))

        XCTAssertEqual(
            coordinator.history,
            [.general, .about, .plugins(.dashboardLayout)]
        )
        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
        XCTAssertFalse(coordinator.canGoForward)
    }

    func testHistoryKeepsOnlyTheMostRecent128Destinations() {
        let coordinator = SettingsNavigationCoordinator()

        for index in 0..<200 {
            coordinator.navigate(to: index.isMultiple(of: 2) ? .about : .general)
        }

        XCTAssertEqual(coordinator.history.count, 128)
        XCTAssertEqual(coordinator.historyIndex, 127)
        XCTAssertEqual(coordinator.history.first, .about)
        XCTAssertEqual(coordinator.destination, .general)

        coordinator.goBack()

        XCTAssertEqual(coordinator.historyIndex, 126)
        XCTAssertEqual(coordinator.destination, .about)
    }

    func testTraversalSkipsPluginConfigurationsThatAreNoLongerAvailable() {
        var availableConfigurationIDs: Set<String> = ["fan-control"]
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { availableConfigurationIDs.contains($0) }
        )

        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .plugins(.marketplace))
        availableConfigurationIDs.remove("fan-control")

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertTrue(coordinator.canGoForward)

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
    }

    func testUnavailableCurrentPluginConfigurationFallsBackWithoutNoOpHistoryTraversal() {
        var availableConfigurationIDs: Set<String> = ["fan-control"]
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { availableConfigurationIDs.contains($0) }
        )

        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        availableConfigurationIDs.remove("fan-control")

        coordinator.reconcileCurrentDestinationAvailability()

        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
        XCTAssertEqual(
            coordinator.history,
            [
                .general,
                .plugins(.marketplace),
                .plugins(.configuration("fan-control")),
                .plugins(.marketplace)
            ]
        )

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .general)
    }

    func testNewSettingsWindowCoordinatorStartsWithFreshHistory() {
        let firstCoordinator = SettingsNavigationCoordinator()
        firstCoordinator.navigate(to: .about)

        let reopenedCoordinator = SettingsNavigationCoordinator()

        XCTAssertEqual(firstCoordinator.history, [.general, .about])
        XCTAssertEqual(reopenedCoordinator.history, [.general])
        XCTAssertFalse(reopenedCoordinator.canGoBack)
    }
}
