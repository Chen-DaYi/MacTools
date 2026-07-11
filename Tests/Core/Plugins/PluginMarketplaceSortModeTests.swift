import XCTest
@testable import MacTools

final class PluginMarketplaceSortModeTests: XCTestCase {
    func testPersistedRawValuesRemainStableForUserDefaults() {
        XCTAssertEqual(PluginMarketplaceSortMode.notInstalledFirst.rawValue, "statusThenName")
        XCTAssertEqual(PluginMarketplaceSortMode.installedFirst.rawValue, "installedThenName")
        XCTAssertEqual(PluginMarketplaceSortMode.nameAscending.rawValue, "nameAscending")
        XCTAssertEqual(PluginMarketplaceSortMode.nameDescending.rawValue, "nameDescending")
        XCTAssertEqual(
            PluginMarketplaceSortMode(rawValue: "statusThenName"),
            .notInstalledFirst
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode(rawValue: "installedThenName"),
            .installedFirst
        )
    }

    func testAllCasesOrderMatchesPickerOrder() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.allCases,
            [
                .notInstalledFirst,
                .installedFirst,
                .nameAscending,
                .nameDescending
            ]
        )
    }

    func testNotInstalledFirstSortRankOrdersInstallableBeforeInstalled() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "a", title: "A", state: .available)),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "b", title: "B", state: .localDevelopment)),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(
                for: makeItem(
                    id: "c",
                    title: "C",
                    state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "1.1.0")
                )
            ),
            1
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "d", title: "D", state: .restartRequired)),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "e", title: "E", state: .failed("x"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "f", title: "F", state: .incompatible("old"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "g", title: "G", state: .revoked("gone"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "h", title: "H", state: .enabled)),
            3
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "i", title: "I", state: .disabled)),
            3
        )
    }

    func testInstalledFirstSortRankPrioritizesUpdatesAndIssues() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(
                for: makeItem(
                    id: "u",
                    title: "U",
                    state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "1.1.0")
                )
            ),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "f", title: "F", state: .failed("x"))),
            1
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "e", title: "E", state: .enabled)),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "a", title: "A", state: .available)),
            3
        )
    }

    func testNotInstalledFirstGroupsByStatusThenSortsByTitle() {
        let sortedIDs = PluginMarketplaceSortMode.sorted(sampleStatusItems(), by: .notInstalledFirst).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "available-a",
                "available-b",
                "update-a",
                "failed",
                "installed-a",
                "installed-z"
            ]
        )
    }

    func testInstalledFirstPrioritizesUpdatesThenIssuesThenInstalledThenAvailable() {
        let sortedIDs = PluginMarketplaceSortMode.sorted(sampleStatusItems(), by: .installedFirst).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "update-a",
                "failed",
                "installed-a",
                "installed-z",
                "available-a",
                "available-b"
            ]
        )
    }

    func testNameAscendingAndDescendingIgnoreInstallStatus() {
        let items = [
            makeItem(id: "c", title: "Charlie", state: .enabled),
            makeItem(id: "a", title: "Alpha", state: .available),
            makeItem(id: "b", title: "Bravo", state: .updateAvailable(installedVersion: "1", catalogVersion: "2"))
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending).map(\.id),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending).map(\.id),
            ["c", "b", "a"]
        )
    }

    func testNameSortUsesIDAsStableTieBreaker() {
        let items = [
            makeItem(id: "plugin-b", title: "Same", state: .available),
            makeItem(id: "plugin-a", title: "Same", state: .enabled)
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending).map(\.id),
            ["plugin-a", "plugin-b"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending).map(\.id),
            ["plugin-b", "plugin-a"]
        )
    }

    func testStatusModesStillGroupAcrossAlphabeticalCatalogOrder() {
        let items = [
            makeItem(id: "zebra-installed", title: "Zebra", state: .enabled),
            makeItem(id: "apple-available", title: "Apple", state: .available),
            makeItem(
                id: "mango-update",
                title: "Mango",
                state: .updateAvailable(installedVersion: "1", catalogVersion: "2")
            )
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .notInstalledFirst).map(\.id),
            ["apple-available", "mango-update", "zebra-installed"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .installedFirst).map(\.id),
            ["mango-update", "zebra-installed", "apple-available"]
        )
    }

    func testCompareIsSymmetricForDistinctRanks() {
        let available = makeItem(id: "a", title: "A", state: .available)
        let enabled = makeItem(id: "e", title: "E", state: .enabled)

        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(available, enabled, mode: .notInstalledFirst),
            .orderedAscending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(enabled, available, mode: .notInstalledFirst),
            .orderedDescending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(enabled, available, mode: .installedFirst),
            .orderedAscending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(available, enabled, mode: .installedFirst),
            .orderedDescending
        )
    }

    func testNameComparePreservesOrderedSameWhenTitleAndIDMatch() {
        let item = makeItem(id: "same-id", title: "Same", state: .available)
        let duplicate = makeItem(id: "same-id", title: "Same", state: .enabled)

        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(item, duplicate, mode: .nameAscending),
            .orderedSame
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(item, duplicate, mode: .nameDescending),
            .orderedSame
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(duplicate, item, mode: .nameDescending),
            .orderedSame
        )
    }

    private func sampleStatusItems() -> [PluginManagementItem] {
        [
            makeItem(id: "installed-z", title: "Zeta", state: .enabled),
            makeItem(id: "available-b", title: "Beta", state: .available),
            makeItem(
                id: "update-a",
                title: "Alpha Update",
                state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0")
            ),
            makeItem(id: "available-a", title: "Alpha", state: .available),
            makeItem(id: "failed", title: "Failed", state: .failed("boom")),
            makeItem(id: "installed-a", title: "Alpha Installed", state: .disabled)
        ]
    }

    private func makeItem(
        id: String,
        title: String,
        state: PluginManagementItem.State
    ) -> PluginManagementItem {
        PluginManagementItem(
            id: id,
            title: title,
            summary: nil,
            version: "1.0.0",
            state: state,
            packageURL: nil,
            requiresRestartToFullyUnload: false,
            releaseNotesURL: nil,
            category: "system"
        )
    }
}
