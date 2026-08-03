import XCTest
@testable import MacTools

@MainActor
final class AppURLRouterTests: XCTestCase {
    func testParserAcceptsDocumentedReleaseAndDebugRoutes() throws {
        let routes: [(String, AppDeepLink)] = [
            ("settings", .settings(.root)),
            ("settings/general", .settings(.general)),
            ("settings/about", .settings(.about)),
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

    func testParserToleratesTrailingSlashAndUniqueOptionalParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/about/?source=website&campaign=launch")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .success(.settings(.about))
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
            ("mactools://app/settings/plugins/fan-control%0A", .malformedPluginID),
            ("mactools://app/settings/plugins/fan-control%0D", .malformedPluginID),
            ("mactools://app/settings/unknown", .unsupportedRoute),
            ("mactools://app//settings", .unsupportedRoute),
            ("mactools://app/settings//", .unsupportedRoute),
            ("mactools://app/panels/dashboard//", .unsupportedRoute),
            ("mactools://app/search//", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control//", .unsupportedRoute),
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
}
