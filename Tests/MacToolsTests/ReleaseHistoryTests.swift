import XCTest
@testable import MacTools

final class ReleaseHistoryTests: XCTestCase {
    func testBundledHistoryIncludesExistingAppAndPluginReleases() {
        let releaseIDs = Set(ReleaseHistory.bundled.releases.map(\.id))

        XCTAssertTrue(releaseIDs.contains("v1.1.6"))
        XCTAssertTrue(releaseIDs.contains("plugins-1.1.6"))
        XCTAssertTrue(releaseIDs.contains("v1.0.28"))
        XCTAssertTrue(releaseIDs.contains("plugins-1.0.29"))
    }

    func testDecodesBundledReleaseHistorySchema() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "releases": [
                {
                  "id": "v1.2.0",
                  "kind": "app",
                  "version": "1.2.0",
                  "date": "2026-08-17",
                  "sections": [
                    {
                      "kind": "added",
                      "entries": ["Added version history to About."]
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        let history = try ReleaseHistory.decode(data)

        XCTAssertEqual(history.releases.count, 1)
        XCTAssertEqual(history.releases[0].kind, .app)
        XCTAssertEqual(history.releases[0].sections[0].kind, .added)
    }

    func testRejectsUnsupportedBundledReleaseHistorySchema() {
        let data = Data("{\"schemaVersion\":2,\"releases\":[]}".utf8)

        XCTAssertThrowsError(try ReleaseHistory.decode(data)) { error in
            XCTAssertEqual(error as? ReleaseHistoryError, .unsupportedSchema(2))
        }
    }

    func testReturnsOnlyRequestedRecentReleases() {
        let releases = (1...12).map { index in
            ReleaseHistoryItem(
                id: "release-\(index)",
                kind: .app,
                version: "1.0.\(index)",
                date: "2026-08-17",
                sections: []
            )
        }
        let history = ReleaseHistory(schemaVersion: 1, releases: releases)

        XCTAssertEqual(
            history.mostRecentReleases(limit: 10).map(\.id),
            Array(releases.prefix(10)).map(\.id)
        )
        XCTAssertEqual(history.releases.count, 12)
        XCTAssertTrue(history.mostRecentReleases(limit: 0).isEmpty)
    }
}
