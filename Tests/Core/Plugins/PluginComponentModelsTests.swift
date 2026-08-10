import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class PluginComponentModelsTests: XCTestCase {
    func testComponentCardTintAdaptsToAppearanceAndContrast() {
        XCTAssertEqual(
            PluginComponentTheme.Opacity.cardTint(
                colorScheme: .light,
                contrast: .standard
            ),
            0.05,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.cardTint(
                colorScheme: .dark,
                contrast: .standard
            ),
            0.07,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.cardTint(
                colorScheme: .light,
                contrast: .increased
            ),
            0.08,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.cardTint(
                colorScheme: .dark,
                contrast: .increased
            ),
            0.12,
            accuracy: 0.001
        )
    }

    func testComponentInternalSurfaceTintsAdaptToAppearanceAndContrast() {
        XCTAssertEqual(
            PluginComponentTheme.Opacity.nestedTint(
                colorScheme: .light,
                contrast: .standard
            ),
            0.58,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.nestedTint(
                colorScheme: .dark,
                contrast: .standard
            ),
            0.06,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.controlTint(
                colorScheme: .light,
                contrast: .standard
            ),
            0.055,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.controlHoverTint(
                colorScheme: .light,
                contrast: .standard
            ),
            0.10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.controlHoverTint(
                colorScheme: .dark,
                contrast: .increased
            ),
            0.20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PluginComponentTheme.Opacity.trackTint(
                colorScheme: .dark,
                contrast: .standard
            ),
            0.12,
            accuracy: 0.001
        )

        let darkIncreasedTheme = PluginComponentTheme.system(
            colorScheme: .dark,
            contrast: .increased
        )
        XCTAssertEqual(darkIncreasedTheme.interaction.selectionOpacity, 0.24, accuracy: 0.001)
        XCTAssertEqual(darkIncreasedTheme.interaction.emphasisOpacity, 0.15, accuracy: 0.001)
    }
}

final class MenuBarControlItemDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarControlItemDefaultsTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    func testVisibleControlItemPreflightDoesNotForcePreferredPosition() {
        MenuBarControlItemDefaults.prepareVisibleControlItem(userDefaults: userDefaults)

        XCTAssertNil(
            userDefaults.object(forKey: preferredPositionKey(MenuBarControlItemDefaults.visibleAutosaveName))
        )
        XCTAssertTrue(userDefaults.bool(forKey: visibleKey(MenuBarControlItemDefaults.visibleAutosaveName)))
        XCTAssertTrue(userDefaults.bool(forKey: visibleControlCenterKey(MenuBarControlItemDefaults.visibleAutosaveName)))
    }

    func testVisibleControlItemPreflightRestoresBackedUpPreferredPositionWhenMissing() {
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(9, userDefaults: userDefaults)
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition(userDefaults: userDefaults)
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(nil, userDefaults: userDefaults)

        MenuBarControlItemDefaults.prepareVisibleControlItem(userDefaults: userDefaults)

        XCTAssertEqual(MenuBarControlItemDefaults.visibleControlItemPreferredPosition(userDefaults: userDefaults), 9)
    }

    func testVisibleControlItemSnapshotKeepsPreviousBackupWhenSystemPreferredPositionIsMissing() {
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(6, userDefaults: userDefaults)
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition(userDefaults: userDefaults)
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(nil, userDefaults: userDefaults)

        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition(userDefaults: userDefaults)
        MenuBarControlItemDefaults.restoreVisibleControlItemPreferredPositionIfMissing(userDefaults: userDefaults)

        XCTAssertEqual(MenuBarControlItemDefaults.visibleControlItemPreferredPosition(userDefaults: userDefaults), 6)
    }

    func testVisibleControlItemPositionResetRestoresPositionRightOfHiddenDivider() {
        userDefaults.set(12, forKey: preferredPositionKey(MenuBarControlItemDefaults.visibleAutosaveName))

        MenuBarControlItemDefaults.resetVisibleControlItemPosition(userDefaults: userDefaults)

        XCTAssertEqual(
            userDefaults.double(forKey: preferredPositionKey(MenuBarControlItemDefaults.visibleAutosaveName)),
            0.5
        )
    }

    func testHiddenDividerCanInitializeLeftOfCurrentVisiblePosition() {
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(8, userDefaults: userDefaults)

        MenuBarControlItemDefaults.prepareHiddenDividerControlItem(
            preferredPosition: MenuBarControlItemDefaults.preferredPositionForHiddenDividerLeftOfVisibleControlItem(
                userDefaults: userDefaults
            ),
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            userDefaults.double(forKey: preferredPositionKey(MenuBarControlItemDefaults.hiddenAutosaveName)),
            8.5
        )
    }

    func testVisibleRecoveryUsesCurrentDividerPosition() {
        MenuBarControlItemDefaults.setHiddenDividerControlItemPreferredPosition(8, userDefaults: userDefaults)

        XCTAssertEqual(
            MenuBarControlItemDefaults.preferredPositionForVisibleControlItemRightOfHiddenDivider(
                userDefaults: userDefaults
            ),
            7.5
        )
    }

    func testVisibleControlItemNeedsRecoveryWhenStoredLeftOfHiddenDivider() {
        MenuBarControlItemDefaults.setHiddenDividerControlItemPreferredPosition(8, userDefaults: userDefaults)
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(9, userDefaults: userDefaults)

        XCTAssertTrue(MenuBarControlItemDefaults.visibleControlItemNeedsRecovery(userDefaults: userDefaults))

        MenuBarControlItemDefaults.resetVisibleControlItemPosition(userDefaults: userDefaults)

        XCTAssertFalse(MenuBarControlItemDefaults.visibleControlItemNeedsRecovery(userDefaults: userDefaults))
        XCTAssertEqual(MenuBarControlItemDefaults.visibleControlItemPreferredPosition(userDefaults: userDefaults), 7.5)
    }

    func testDividerRecoveryUsesCurrentVisiblePosition() {
        MenuBarControlItemDefaults.setVisibleControlItemPreferredPosition(4, userDefaults: userDefaults)

        XCTAssertEqual(
            MenuBarControlItemDefaults.preferredPositionForHiddenDividerLeftOfVisibleControlItem(
                userDefaults: userDefaults
            ),
            4.5
        )
    }

    func testAlwaysHiddenDividerPreflightDoesNotForcePreferredPosition() {
        MenuBarControlItemDefaults.setAlwaysHiddenDividerControlItemPreferredPosition(8, userDefaults: userDefaults)

        MenuBarControlItemDefaults.prepareAlwaysHiddenDividerControlItem(userDefaults: userDefaults)

        XCTAssertNil(
            userDefaults.object(forKey: preferredPositionKey(MenuBarControlItemDefaults.alwaysHiddenAutosaveName))
        )
        XCTAssertTrue(userDefaults.bool(forKey: visibleKey(MenuBarControlItemDefaults.alwaysHiddenAutosaveName)))
        XCTAssertTrue(userDefaults.bool(forKey: visibleControlCenterKey(MenuBarControlItemDefaults.alwaysHiddenAutosaveName)))
    }

    private func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private func visibleKey(_ autosaveName: String) -> String {
        "NSStatusItem Visible \(autosaveName)"
    }

    private func visibleControlCenterKey(_ autosaveName: String) -> String {
        "NSStatusItem VisibleCC \(autosaveName)"
    }
}
