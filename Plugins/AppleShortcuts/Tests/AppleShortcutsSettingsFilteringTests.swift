import Foundation
import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsSettingsFilteringTests: XCTestCase {
    func testAllDiscoveredRowsAreVisibleWithoutEnablementState() throws {
        let folderID = UUID()
        let firstID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let secondID = UUID()
        let rows = [
            AppleShortcutsDisplayRow(item: AppleShortcutItem(id: firstID, name: "Morning", folderIDs: [folderID])),
            AppleShortcutsDisplayRow(item: AppleShortcutItem(id: secondID, name: "Evening")),
        ]

        let all = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .all,
            searchText: "",
            folderIDsByShortcut: [firstID: [folderID]]
        )
        let folder = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .folder(folderID),
            searchText: "",
            folderIDsByShortcut: [firstID: [folderID]]
        )
        let identifierMatch = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .all,
            searchText: "aaaaaaaa-bbbb",
            folderIDsByShortcut: [firstID: [folderID]]
        )

        XCTAssertEqual(all.map(\.id), [firstID, secondID])
        XCTAssertEqual(folder.map(\.id), [firstID])
        XCTAssertEqual(identifierMatch.map(\.id), [firstID])
    }

    func testFolderNamesUseTheSelectedRuntimeLocale() {
        let names = ["Home", "Work"]
        XCTAssertEqual(
            AppleShortcutsSettingsFormatting.joinedFolderNames(names, locale: Locale(identifier: "en")),
            "Home and Work"
        )
        XCTAssertEqual(
            AppleShortcutsSettingsFormatting.joinedFolderNames(names, locale: Locale(identifier: "zh-Hans")),
            "Home和Work"
        )
    }

    func testSettingsRunDispositionHonorsConfirmationPolicy() {
        var immediateRunCount = 0
        var confirmationCount = 0
        AppleShortcutsSettingsRunDisposition.route(
            policy: .default,
            requestConfirmation: { confirmationCount += 1 },
            run: { immediateRunCount += 1 }
        )
        AppleShortcutsSettingsRunDisposition.route(
            policy: AppleShortcutPolicy(requiresConfirmation: false),
            requestConfirmation: { confirmationCount += 1 },
            run: { immediateRunCount += 1 }
        )

        XCTAssertEqual(immediateRunCount, 1)
        XCTAssertEqual(confirmationCount, 1)
    }
}
