import Foundation
import XCTest
@testable import MacTools

@MainActor
final class PluginDisplayPreferencesStoreTests: XCTestCase {
    private struct LegacyPreferences: Codable {
        let orderedPluginIDs: [String]
        let hiddenPluginIDs: Set<String>
    }

    private struct FuturePreferences: Codable {
        let version: Int
        let generalPluginOrder: [String]
        let futureOnlyValue: String
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: PluginDisplayPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "PluginDisplayPreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = PluginDisplayPreferencesStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testVersionOneMigrationPreservesGeneralOrderAndGlobalDisablement() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar"],
            hidden: ["activity"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(defaultPluginIDs: ["calendar", "display", "activity"]),
            ["display", "activity", "calendar"]
        )
        XCTAssertFalse(store.isPluginGloballyEnabled("activity"))
        XCTAssertTrue(store.isPluginGloballyEnabled("calendar"))
    }

    func testLegacyOrderSeedsEachSurfaceByCapabilityFilteredDefaults() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar", "fan", "status"],
            hidden: []
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar", "status"]
            ),
            ["activity", "calendar", "status"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .featurePanel,
                defaultPluginIDs: ["display", "activity", "fan"]
            ),
            ["display", "activity", "fan"]
        )
    }

    func testDeferredPluginLoadingDoesNotConsumeLegacySurfaceMigration() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar"],
            hidden: []
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: []),
            []
        )
        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar"]
            ),
            ["activity", "calendar"]
        )
    }

    func testSurfaceOrdersAreIndependent() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )
        store.setOrderedPluginIDs(
            ["fan", "activity"],
            for: .featurePanel,
            defaultPluginIDs: ["activity", "fan"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["calendar", "activity"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "fan"]),
            ["fan", "activity"]
        )
    }

    func testNewPluginsAppendInDefaultOrder() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar", "status"]
            ),
            ["calendar", "activity", "status"]
        )
    }

    func testTemporarilyMissingPluginOrderRemainsRecoverable() {
        store.setOrderedPluginIDs(
            ["first", "missing", "second"],
            for: .dashboard,
            defaultPluginIDs: ["first", "missing", "second"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["first", "second"]),
            ["first", "second"]
        )

        store.setOrderedPluginIDs(
            ["second", "first"],
            for: .dashboard,
            defaultPluginIDs: ["first", "second"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["first", "missing", "second"]
            ),
            ["second", "missing", "first"]
        )
    }

    func testCorruptDataFallsBackToCapabilityFilteredDefaults() {
        let invalidData = Data("not-json".utf8)
        defaults.set(invalidData, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "status"]),
            ["calendar", "status"]
        )
        XCTAssertTrue(store.isPluginGloballyEnabled("calendar"))
        XCTAssertEqual(defaults.data(forKey: "plugin.display.preferences"), invalidData)
    }

    func testUnknownFutureVersionFallsBackWithoutDeletingStoredPayload() throws {
        let futureData = try JSONEncoder().encode(
            FuturePreferences(
                version: 99,
                generalPluginOrder: ["future"],
                futureOnlyValue: "preserve-me"
            )
        )
        defaults.set(futureData, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "status"]),
            ["calendar", "status"]
        )
        XCTAssertEqual(defaults.data(forKey: "plugin.display.preferences"), futureData)
    }

    func testResettingOneSurfaceDoesNotAffectTheOther() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )
        store.setOrderedPluginIDs(
            ["fan", "activity"],
            for: .featurePanel,
            defaultPluginIDs: ["activity", "fan"]
        )
        store.resetOrder(for: .dashboard, defaultPluginIDs: ["activity", "calendar"])

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["activity", "calendar"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "fan"]),
            ["fan", "activity"]
        )
    }

    func testSettingsOnlyPluginIsExcludedWhenNotInSurfaceDefaults() {
        store.setOrderedPluginIDs(
            ["right-click", "activity"],
            defaultPluginIDs: ["right-click", "activity"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["activity"]),
            ["activity"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity"]),
            ["activity"]
        )
    }

    private func storeLegacyPreferences(order: [String], hidden: Set<String>) throws {
        let data = try JSONEncoder().encode(
            LegacyPreferences(orderedPluginIDs: order, hiddenPluginIDs: hidden)
        )
        defaults.set(data, forKey: "plugin.display.preferences")
    }
}
