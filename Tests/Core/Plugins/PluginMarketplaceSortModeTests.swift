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

    func testUninstallScopeFallsBackToMacToolsWithoutCapabilityMetadata() {
        let item = makeItem(id: "legacy", title: "Legacy", state: .installed)

        XCTAssertEqual(item.uninstallScopeSummary, "MacTools")
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
            makeItem(id: "c", title: "Charlie", state: .installed),
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

    func testNameSortUsesSimplifiedChineseCollation() {
        let items = [
            makeItem(id: "calendar", title: "日历", state: .available),
            makeItem(id: "fan-control", title: "风扇控制", state: .available),
            makeItem(id: "stage-manager", title: "台前调度", state: .available),
            makeItem(id: "right-click", title: "右键工具", state: .available),
            makeItem(id: "battery-limit", title: "电池充电上限", state: .available),
            makeItem(id: "auto-hide-dock", title: "自动隐藏程序坞", state: .available)
        ]
        let locale = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending, locale: locale).map(\.id),
            ["battery-limit", "fan-control", "calendar", "stage-manager", "right-click", "auto-hide-dock"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending, locale: locale).map(\.id),
            ["auto-hide-dock", "right-click", "stage-manager", "calendar", "fan-control", "battery-limit"]
        )
    }

    func testNameSortUsesJapaneseCollation() {
        let items = [
            makeItem(id: "right-click", title: "右クリック", state: .available),
            makeItem(id: "lock-screen", title: "画面をロック", state: .available),
            makeItem(id: "fix-damaged-app", title: "破損したアプリを修復", state: .available),
            makeItem(id: "launch-control", title: "起動項目", state: .available),
            makeItem(id: "translator", title: "翻訳", state: .available)
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending, locale: Locale(identifier: "ja")).map(\.id),
            ["right-click", "lock-screen", "launch-control", "fix-damaged-app", "translator"]
        )
    }

    func testNameSortUsesIDAsStableTieBreaker() {
        let items = [
            makeItem(id: "plugin-b", title: "Same", state: .available),
            makeItem(id: "plugin-a", title: "Same", state: .installed)
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
            makeItem(id: "zebra-installed", title: "Zebra", state: .installed),
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

    private func sampleStatusItems() -> [PluginManagementItem] {
        [
            makeItem(id: "installed-z", title: "Zeta", state: .installed),
            makeItem(id: "available-b", title: "Beta", state: .available),
            makeItem(
                id: "update-a",
                title: "Alpha Update",
                state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0")
            ),
            makeItem(id: "available-a", title: "Alpha", state: .available),
            makeItem(id: "failed", title: "Failed", state: .failed("boom")),
            makeItem(id: "installed-a", title: "Alpha Installed", state: .installed)
        ]
    }

    private func makeItem(
        id: String,
        title: String,
        state: PluginManagementItem.State,
        capabilities: PluginPackageManifest.Capabilities? = nil
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
            category: "system",
            capabilities: capabilities
        )
    }
}
