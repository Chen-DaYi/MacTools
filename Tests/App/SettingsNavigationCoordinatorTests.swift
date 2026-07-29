import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class SettingsNavigationCoordinatorTests: XCTestCase {
    func testPluginSidebarOrderPlacesBuiltInPanesBeforeDisplayedConfigurations() {
        XCTAssertEqual(
            FeatureSettingsPane.settingsSidebarOrder(
                configurationIDs: ["calendar", "fan-control"]
            ),
            [
                .dashboardLayout,
                .featurePanelLayout,
                .marketplace,
                .configuration("calendar"),
                .configuration("fan-control")
            ]
        )
    }

    func testMovesPluginSubpageInSuppliedVisibleOrder() {
        let orderedPanes: [FeatureSettingsPane] = [
            .configuration("fan-control"),
            .marketplace,
            .dashboardLayout
        ]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.marketplace),
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        coordinator.movePluginSubpage(.previous, in: orderedPanes)
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))

        coordinator.movePluginSubpage(.next, in: orderedPanes)
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))

        coordinator.movePluginSubpage(.next, in: orderedPanes)
        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
    }

    func testPluginSubpageMovementStopsAtBothBoundaries() {
        let orderedPanes: [FeatureSettingsPane] = [
            .dashboardLayout,
            .featurePanelLayout,
            .marketplace
        ]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.dashboardLayout)
        )

        coordinator.movePluginSubpage(.previous, in: orderedPanes)
        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
        XCTAssertEqual(coordinator.history, [.plugins(.dashboardLayout)])

        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.movePluginSubpage(.next, in: orderedPanes)
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
        XCTAssertEqual(
            coordinator.history,
            [.plugins(.dashboardLayout), .plugins(.marketplace)]
        )
    }

    func testPluginSubpageMovementDoesNothingOutsidePlugins() {
        let coordinator = SettingsNavigationCoordinator(initialDestination: .about)

        coordinator.movePluginSubpage(
            .next,
            in: [.dashboardLayout, .featurePanelLayout, .marketplace]
        )

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertEqual(coordinator.history, [.about])
    }

    func testPluginSubpageMovementRecordsHistoryAndInvalidatesForwardHistory() {
        let orderedPanes: [FeatureSettingsPane] = [
            .dashboardLayout,
            .featurePanelLayout,
            .marketplace
        ]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.dashboardLayout)
        )
        coordinator.navigate(to: .plugins(.featurePanelLayout))
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.goBack()

        coordinator.movePluginSubpage(.previous, in: orderedPanes)

        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
        XCTAssertEqual(
            coordinator.history,
            [
                .plugins(.dashboardLayout),
                .plugins(.featurePanelLayout),
                .plugins(.dashboardLayout)
            ]
        )
        XCTAssertFalse(coordinator.canGoForward)
    }

    func testPluginSubpageMovementIgnoresRemovedCurrentConfiguration() {
        var availableConfigurationIDs: Set<String> = ["fan-control"]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.configuration("fan-control")),
            isPluginConfigurationAvailable: { availableConfigurationIDs.contains($0) }
        )
        availableConfigurationIDs.remove("fan-control")

        coordinator.movePluginSubpage(
            .previous,
            in: [.dashboardLayout, .featurePanelLayout, .marketplace]
        )

        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
        XCTAssertEqual(coordinator.history, [.plugins(.configuration("fan-control"))])
    }

    func testPluginSubpageMovementReadsLatestDynamicOrder() {
        var configurationIDs: [String] = []
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.marketplace),
            pluginSubpageOrder: {
                FeatureSettingsPane.settingsSidebarOrder(
                    configurationIDs: configurationIDs
                )
            },
            isPluginConfigurationAvailable: { configurationIDs.contains($0) }
        )

        coordinator.movePluginSubpage(.next)
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))

        configurationIDs = ["fan-control"]
        coordinator.movePluginSubpage(.next)

        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
    }

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

    func testSearchFocusRequestsAreContextualAndRepeatOnlyAfterFocusLeaves() {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertNil(coordinator.searchFocusRequest)

        coordinator.navigate(to: .plugins(.marketplace))
        XCTAssertTrue(coordinator.requestSearchFocus())
        let firstRequest = coordinator.searchFocusRequest
        XCTAssertEqual(firstRequest?.field, .pluginMarketplace)

        coordinator.setSearchField(.pluginMarketplace, focused: true)
        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertEqual(coordinator.searchFocusRequest, firstRequest)

        coordinator.setSearchField(.pluginMarketplace, focused: false)
        XCTAssertTrue(coordinator.requestSearchFocus())
        XCTAssertNotEqual(coordinator.searchFocusRequest, firstRequest)
    }

    func testSearchFocusIsNoOpOnEveryNonSearchableSettingsDestination() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )
        let destinations: [SettingsNavigationDestination] = [
            .general,
            .about,
            .plugins(.dashboardLayout),
            .plugins(.featurePanelLayout),
            .plugins(.configuration("fan-control"))
        ]

        for destination in destinations {
            coordinator.navigate(to: destination)
            XCTAssertFalse(coordinator.requestSearchFocus(), "\(destination) should not request search focus")
        }

        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testAboutUpdateActionNavigatesAndCanOnlyBeConsumedOnce() throws {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.requestAboutUpdateAction(version: "1.2.3")

        XCTAssertEqual(coordinator.destination, .about)
        let request = try XCTUnwrap(coordinator.aboutUpdateActionRequest)
        XCTAssertEqual(request.version, "1.2.3")
        XCTAssertTrue(coordinator.consumeAboutUpdateActionRequest(request))
        XCTAssertNil(coordinator.aboutUpdateActionRequest)
        XCTAssertFalse(coordinator.consumeAboutUpdateActionRequest(request))
    }

    func testRegularAboutNavigationDoesNotRequestAutomaticUpdateAction() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertNil(coordinator.aboutUpdateActionRequest)
    }

    func testRepeatedAboutUpdateActionsUseDistinctRequests() throws {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.requestAboutUpdateAction(version: "1.2.3")
        let firstRequest = try XCTUnwrap(coordinator.aboutUpdateActionRequest)
        coordinator.requestAboutUpdateAction(version: "1.2.3")
        let secondRequest = try XCTUnwrap(coordinator.aboutUpdateActionRequest)

        XCTAssertNotEqual(firstRequest.id, secondRequest.id)
    }

    func testUnifiedSearchPresentationTracksOriginAndRepeatedFocusRequests() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.presentUnifiedSearch(origin: .pluginSidebar)
        let firstFocusRequestID = coordinator.unifiedSearchFocusRequestID

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .pluginSidebar)

        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .keyboard)
        XCTAssertGreaterThan(coordinator.unifiedSearchFocusRequestID, firstFocusRequestID)

        coordinator.dismissUnifiedSearch()

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(coordinator.unifiedSearchPresentationOrigin)
    }

    func testLocalSearchFocusDoesNotMoveBehindUnifiedSearch() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testUnifiedSearchQuickSelectionRequestsAreValidatedAndRepeatable() throws {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        coordinator.presentUnifiedSearch(origin: .keyboard)
        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 0))
        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 10))

        XCTAssertTrue(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        let firstRequest = try XCTUnwrap(coordinator.unifiedSearchQuickSelectionRequest)
        XCTAssertEqual(firstRequest.number, 1)

        XCTAssertTrue(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        let secondRequest = try XCTUnwrap(coordinator.unifiedSearchQuickSelectionRequest)
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)

        coordinator.dismissUnifiedSearch()
        XCTAssertNil(coordinator.unifiedSearchQuickSelectionRequest)
    }

    func testUnifiedSearchQuickSelectionRequestCanOnlyBeConsumedOnce() throws {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.presentUnifiedSearch(origin: .keyboard)
        XCTAssertTrue(coordinator.requestUnifiedSearchQuickSelection(number: 2))
        let request = try XCTUnwrap(
            coordinator.unifiedSearchQuickSelectionRequest
        )

        XCTAssertTrue(
            coordinator.consumeUnifiedSearchQuickSelectionRequest(request)
        )
        XCTAssertNil(coordinator.unifiedSearchQuickSelectionRequest)
        XCTAssertFalse(
            coordinator.consumeUnifiedSearchQuickSelectionRequest(request)
        )
    }

    func testSearchNavigationKeepsPaletteOpenForUnavailablePlugin() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { _ in false }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("removed-plugin")),
            target: .plugin(
                PluginSettingsSearchTarget(
                    pluginID: "removed-plugin",
                    entryID: "setting"
                )
            )
        )

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationKeepsPaletteOpenForUnavailableSurfacePlugin() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginSurfaceAvailable: { _ in false }
        )
        let target = SurfaceSettingsSearchTarget(
            surface: .featurePanel,
            pluginID: "removed-plugin"
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.featurePanelLayout),
            target: .surface(target)
        )

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationKeepsPaletteOpenForUnavailableExactPluginEntry() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "installed-plugin" },
            isPluginSettingsSearchTargetAvailable: { _ in false }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "installed-plugin",
            entryID: "removed-setting"
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(
            coordinator.navigateFromSearch(
                to: .plugins(.configuration("installed-plugin")),
                target: .plugin(target)
            )
        )
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationRejectsMismatchedTargetAndDestination() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(
            coordinator.navigateFromSearch(
                to: .plugins(.featurePanelLayout),
                target: .surface(
                    SurfaceSettingsSearchTarget(
                        surface: .dashboard,
                        pluginID: "display"
                    )
                )
            )
        )
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationRevealsAvailableMarketplacePlugin() throws {
        let target = MarketplacePluginSearchTarget(pluginID: "failed-plugin")
        let coordinator = SettingsNavigationCoordinator(
            isPluginManagementAvailable: { $0 == target.pluginID }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(
            coordinator.navigateFromSearch(
                to: .plugins(.marketplace),
                target: .marketplace(target)
            )
        )
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
        XCTAssertEqual(
            try XCTUnwrap(coordinator.searchRevealRequest).target,
            .marketplace(target)
        )
    }

    func testSearchNavigationAllowsAvailableSurfacePlugin() throws {
        let expectedTarget = SurfaceSettingsSearchTarget(
            surface: .dashboard,
            pluginID: "hidden-plugin"
        )
        var validatedTargets: [SurfaceSettingsSearchTarget] = []
        let coordinator = SettingsNavigationCoordinator(
            isPluginSurfaceAvailable: { target in
                validatedTargets.append(target)
                return target == expectedTarget
            }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.dashboardLayout),
            target: .surface(expectedTarget)
        )

        XCTAssertEqual(validatedTargets, [expectedTarget])
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
        XCTAssertEqual(
            try XCTUnwrap(coordinator.searchRevealRequest).target,
            .surface(expectedTarget)
        )
    }

    func testSearchNavigationDismissesPaletteAndPublishesExactRevealTarget() throws {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "keep-awake" }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "keep-awake",
            entryID: "keep-display-on"
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("keep-awake")),
            target: .plugin(target)
        )

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(
            coordinator.destination,
            .plugins(.configuration("keep-awake"))
        )
        let request = try XCTUnwrap(coordinator.searchRevealRequest)
        XCTAssertEqual(request.target, .plugin(target))

        coordinator.clearSearchRevealRequest(request)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testPageLevelSearchNavigationClearsPreviousRevealTarget() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "keep-awake" }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "keep-awake",
            entryID: "keep-display-on"
        )

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("keep-awake")),
            target: .plugin(target)
        )
        coordinator.navigateFromSearch(to: .about, target: nil)

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testGeneralSettingSearchNavigationPublishesExactRevealTarget() throws {
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .about
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .general,
            target: .general(.language)
        )

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        let request = try XCTUnwrap(coordinator.searchRevealRequest)
        XCTAssertEqual(request.target, .general(.language))
    }

    func testClearingRevealTargetOnlyClearsTheMatchingRequest() throws {
        let coordinator = SettingsNavigationCoordinator(initialDestination: .about)
        coordinator.navigateFromSearch(
            to: .general,
            target: .general(.language)
        )

        coordinator.clearSearchRevealRequest(matching: .general(.appearance))
        XCTAssertNotNil(coordinator.searchRevealRequest)

        coordinator.clearSearchRevealRequest(matching: .general(.language))
        XCTAssertNil(coordinator.searchRevealRequest)
    }
}
