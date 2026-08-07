import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AppURLRouterTests: XCTestCase {
    func testParserAcceptsDocumentedReleaseAndDebugRoutes() throws {
        let routes: [(String, AppDeepLink)] = [
            ("settings", .settings(.root)),
            ("settings/general", .settings(.general)),
            ("settings/about", .settings(.about)),
            ("settings/features/actions-and-shortcuts", .settings(.actionsAndShortcuts)),
            ("settings/features/automation", .settings(.automation)),
            ("settings/plugins/marketplace", .settings(.pluginMarketplace)),
            ("settings/plugins/fan-control", .settings(.pluginConfiguration("fan-control"))),
            ("panels/dashboard", .panel(.dashboard)),
            ("panels/feature", .panel(.feature)),
            ("search", .search)
        ]

        for scheme in ["mactools", "mactools-dev"] {
            for (path, expected) in routes {
                let parsed = AppDeepLinkParser.parse(
                    try XCTUnwrap(URL(string: "\(scheme)://app/\(path)")),
                    acceptedSchemes: [scheme]
                )
                XCTAssertEqual(parsed, .success(expected), "Failed route: \(scheme)://app/\(path)")
            }
        }
    }

    func testParserAcceptsDocumentedActionAndPresetRoutesInBothSchemes() throws {
        let presetID = UUID(uuidString: "7B420000-0000-0000-0000-000000000001")!

        for scheme in ["mactools", "mactools-dev"] {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/actions/microphone-mute/toggle")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(
                    .run(
                        .direct(
                            ActionKey(providerID: "microphone-mute", actionID: "toggle")
                        )
                    )
                )
            )
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/presets/\(presetID.uuidString)")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(.run(.preset(presetID)))
            )
        }
    }

    func testNavigationOnlyParserDoesNotExecuteActionRoutes() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/actions/display-sleep/sleep")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.unsupportedRoute)
        )
    }

    func testActionParserRejectsParametersMalformedIDsAndEncodedSeparators() throws {
        let cases: [(String, AppURLRoutingError)] = [
            (
                "mactools://app/actions/display-sleep/sleep?confirm=false",
                .unexpectedActionParameters
            ),
            ("mactools://app/actions/display-sleep/sleep?", .unexpectedActionParameters),
            (
                "mactools://app/actions/display-sleep/sleep?x=1&x=2",
                .duplicatedParameter("x")
            ),
            ("mactools://app/actions/a/b", .malformedActionID),
            ("mactools://app/actions/display-sleep/bad%20id", .malformedActionID),
            ("mactools://app/actions/display-sleep/sleep%2Fnow", .unsupportedRoute),
            ("mactools://app/actions/display-sleep/%2E%2E", .unsupportedRoute),
            ("mactools://app/presets/not-a-uuid", .invalidPresetID),
            (
                "mactools://app/presets/7B420000-0000-0000-0000-000000000001?x=1",
                .unexpectedActionParameters
            ),
        ]

        for (urlString, expected) in cases {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(URL(string: urlString)),
                    acceptedSchemes: ["mactools"]
                ),
                .failure(expected),
                "Unexpected result for \(urlString)"
            )
        }
    }

    func testParserToleratesTrailingSlashAndUniqueOptionalParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/about/?source=website&campaign=launch")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .success(.settings(.about))
        )
    }

    func testParserDecodesSafeCharactersWithinIndividualPathSegments() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/fan%2Dcontrol")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .success(.settings(.pluginConfiguration("fan-control")))
        )
    }

    func testParserRejectsDuplicateParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/search?source=website&source=docs")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.duplicatedParameter("source"))
        )
    }

    func testParserRejectsUnknownAndMalformedDestinations() throws {
        let cases: [(String, AppURLRoutingError)] = [
            ("not-a-url", .malformedURL),
            ("other://app/settings", .unsupportedScheme),
            ("mactools://other/settings", .unsupportedHost),
            ("mactools://app/settings/plugins/a", .malformedPluginID),
            ("mactools://app/settings/plugins/bad%20id", .malformedPluginID),
            ("mactools://app/settings/plugins/fan-control%0A", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control%0D", .unsupportedRoute),
            ("mactools://app/settings/unknown", .unsupportedRoute),
            ("mactools://app//settings", .unsupportedRoute),
            ("mactools://app/settings//", .unsupportedRoute),
            ("mactools://app/panels/dashboard//", .unsupportedRoute),
            ("mactools://app/search//", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control//", .unsupportedRoute),
            ("mactools://app/panels%2Fdashboard", .unsupportedRoute),
            ("mactools://app/panels%2fdashboard", .unsupportedRoute),
            ("mactools://app/settings%2Fplugins%2Ffan-control", .unsupportedRoute),
            ("mactools://app/panels%5Cdashboard", .unsupportedRoute),
            ("mactools://app/settings/%2E%2E/about", .unsupportedRoute),
            ("mactools://app/panels/%00dashboard", .unsupportedRoute),
            ("mactools://app/plugins/fan-control/commands/start", .unsupportedRoute),
            ("mactools://app/search?=value", .unsupportedURLComponents),
            ("mactools://app/settings#private", .unsupportedURLComponents),
            ("mactools://user@app/settings", .unsupportedURLComponents),
            ("mactools://app:/settings", .unsupportedURLComponents),
            ("mactools://app:42/settings", .unsupportedURLComponents)
        ]

        for (urlString, expectedError) in cases {
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertEqual(
                AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
                .failure(expectedError),
                "Unexpected parser result for \(urlString)"
            )
        }
    }

    func testParserRejectsOversizedPublicURL() throws {
        let query = String(repeating: "x", count: AppDeepLinkParser.maximumURLByteCount)
        let url = try XCTUnwrap(URL(string: "mactools://app/search?metadata=\(query)"))

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.oversizedInput)
        )
    }

    func testRightClickRoutesDelegateImmediatelyBeforeActivationInBothBuildSchemes() throws {
        var delegatedURLs: [URL] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools", "mactools-dev"],
            rightClickHandler: { delegatedURLs.append($0) }
        )
        let releaseURL = try XCTUnwrap(
            URL(string: "mactools://right-click/new-folder?directory=/tmp")
        )
        let debugURL = try XCTUnwrap(
            URL(string: "mactools-dev://right-click/open-terminal?directory=/tmp")
        )

        XCTAssertEqual(router.handle(releaseURL), .delegatedToRightClick)
        XCTAssertEqual(router.handle(debugURL), .delegatedToRightClick)
        XCTAssertEqual(delegatedURLs, [releaseURL, debugURL])
    }

    func testRightClickCompatibilityNamespaceDoesNotAdoptPublicURLSizeLimit() throws {
        var delegatedURLs: [URL] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { delegatedURLs.append($0) }
        )
        let longPath = "/tmp/" + String(repeating: "a", count: AppDeepLinkParser.maximumURLByteCount)
        let url = try XCTUnwrap(
            URL(string: "mactools://right-click/open-terminal?directory=\(longPath)")
        )

        XCTAssertEqual(router.handle(url), .delegatedToRightClick)
        XCTAssertEqual(delegatedURLs, [url])
    }

    func testColdLaunchQueueDrainsInArrivalOrderAfterPluginInitialization() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in XCTFail("Unexpected Finder Sync delegation") }
        )
        let general = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let plugin = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/fan-control")
        )

        XCTAssertEqual(router.handle(general), .queued(.settings(.general)))
        XCTAssertEqual(
            router.handle(plugin),
            .queued(.settings(.pluginConfiguration("fan-control")))
        )
        XCTAssertTrue(requests.isEmpty)

        let drained = router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        XCTAssertEqual(
            drained,
            [
                .handled(.settings(.general)),
                .handled(.settings(.pluginConfiguration("fan-control")))
            ]
        )
        XCTAssertEqual(
            requests,
            [
                .settings(.general),
                .settings(.pluginConfiguration("fan-control"))
            ]
        )
    }

    func testUnavailablePluginIsRejectedWhenColdLaunchQueueDrains() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/not-installed")
        )

        XCTAssertEqual(
            router.handle(url),
            .queued(.settings(.pluginConfiguration("not-installed")))
        )
        XCTAssertEqual(
            router.activate(
                presentationHandler: { requests.append($0) },
                isPluginConfigurationAvailable: { _ in false }
            ),
            [.rejected(.unavailablePlugin("not-installed"))]
        )
        XCTAssertTrue(requests.isEmpty)
    }

    func testColdLaunchQueueRejectsOverflowWithoutDisplacingEarlierLinks() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 2,
            rightClickHandler: { _ in }
        )
        let general = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let about = try XCTUnwrap(URL(string: "mactools://app/settings/about"))
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(general), .queued(.settings(.general)))
        XCTAssertEqual(router.handle(about), .queued(.settings(.about)))
        XCTAssertEqual(router.handle(search), .rejected(.pendingQueueFull))

        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true }
        )
        XCTAssertEqual(requests, [.settings(.general), .settings(.about)])
    }

    func testRepeatedPanelAndSearchLinksUseDeterministicPresentationRequests() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true }
        )
        let dashboard = try XCTUnwrap(URL(string: "mactools://app/panels/dashboard"))
        let feature = try XCTUnwrap(URL(string: "mactools://app/panels/feature"))
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(dashboard), .handled(.panel(.dashboard)))
        XCTAssertEqual(router.handle(dashboard), .handled(.panel(.dashboard)))
        XCTAssertEqual(router.handle(feature), .handled(.panel(.feature)))
        XCTAssertEqual(router.handle(search), .handled(.search))
        XCTAssertEqual(
            requests,
            [.showDashboard, .showDashboard, .showFeaturePanel, .showUnifiedSearch]
        )
    }

    func testMixedColdLaunchRoutesPreserveArrivalOrder() async throws {
        enum Event: Equatable {
            case navigation(AppPresentationRequest)
            case action(ActionRunLinkRequest)
        }
        var events: [Event] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in XCTFail("Unexpected delegation") }
        )
        let settings = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/display-sleep/sleep")
        )
        let search = try XCTUnwrap(URL(string: "mactools://app/search"))

        XCTAssertEqual(router.handle(settings), .queued(.settings(.general)))
        XCTAssertEqual(
            router.handle(action),
            .queuedAction(.direct(ActionKey(providerID: "display-sleep", actionID: "sleep")))
        )
        XCTAssertEqual(router.handle(search), .queued(.search))

        let synchronous = router.activate(
            presentationHandler: { request in events.append(.navigation(request)) },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request in events.append(.action(request)) }
        )
        XCTAssertEqual(synchronous, [.handled(.settings(.general))])
        await router.waitUntilIdle()

        XCTAssertEqual(
            events,
            [
                .navigation(.settings(.general)),
                .action(
                    .direct(ActionKey(providerID: "display-sleep", actionID: "sleep"))
                ),
                .navigation(.showUnifiedSearch),
            ]
        )
    }

    func testActiveActionDeliveryIsSerializedAndBacklogIsBounded() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 2,
            rightClickHandler: { _ in }
        )
        var activeCount = 0
        var maximumActiveCount = 0
        var delivered: [ActionRunLinkRequest] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { request in
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                delivered.append(request)
                try? await Task.sleep(for: .milliseconds(10))
                activeCount -= 1
            }
        )
        let first = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/first"))
        let second = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/second"))
        let overflow = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/third"))

        XCTAssertEqual(
            router.handle(first),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "first")))
        )
        XCTAssertEqual(
            router.handle(second),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "second")))
        )
        XCTAssertEqual(router.handle(overflow), .rejected(.pendingQueueFull))
        await router.waitUntilIdle()

        XCTAssertEqual(maximumActiveCount, 1)
        XCTAssertEqual(
            delivered,
            [
                .direct(ActionKey(providerID: "test-provider", actionID: "first")),
                .direct(ActionKey(providerID: "test-provider", actionID: "second")),
            ]
        )
    }

    func testActiveActionCannotRecursivelyQueueItself() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let url = try XCTUnwrap(URL(string: "mactools://app/actions/test-provider/run"))
        var recursiveResult: AppURLHandlingResult?
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { _ in
                recursiveResult = router.handle(url)
            }
        )

        XCTAssertEqual(
            router.handle(url),
            .queuedAction(.direct(ActionKey(providerID: "test-provider", actionID: "run")))
        )
        await router.waitUntilIdle()

        XCTAssertEqual(recursiveResult, .rejected(.recursiveActionInvocation))
    }
}
