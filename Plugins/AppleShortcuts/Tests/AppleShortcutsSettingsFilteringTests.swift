import Foundation
import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsSettingsFilteringTests: XCTestCase {
    func testSearchPreservesDistinctRowsWithDuplicateNamesAndMatchesIdentifier() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let secondID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let rows = [
            row(id: firstID, name: "Morning", isMissing: false),
            row(id: secondID, name: "Morning", isMissing: true),
        ]

        let nameMatches = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .all,
            filter: .all,
            searchText: "MORNING",
            enabledIDs: [],
            folderIDsByShortcut: [:]
        )
        let identifierMatches = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .all,
            filter: .all,
            searchText: "aaaaaaaa-bbbb",
            enabledIDs: [],
            folderIDsByShortcut: [:]
        )

        XCTAssertEqual(nameMatches.map(\.id), [firstID, secondID])
        XCTAssertEqual(identifierMatches.map(\.id), [firstID])
    }

    func testEnabledMissingAndFolderFiltersComposeDeterministically() {
        let folderID = UUID()
        let enabledID = UUID()
        let missingID = UUID()
        let unrelatedID = UUID()
        let rows = [
            row(id: enabledID, name: "Enabled", isMissing: false),
            row(id: missingID, name: "Missing", isMissing: true),
            row(id: unrelatedID, name: "Other", isMissing: false),
        ]
        let folderIDsByShortcut = [
            enabledID: Set([folderID]),
            missingID: Set([folderID]),
        ]

        let enabledFolderRows = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .folder(folderID),
            filter: .enabled,
            searchText: "",
            enabledIDs: [enabledID],
            folderIDsByShortcut: folderIDsByShortcut
        )
        let missingRows = AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: .missing,
            filter: .all,
            searchText: "",
            enabledIDs: [enabledID],
            folderIDsByShortcut: folderIDsByShortcut
        )

        XCTAssertEqual(enabledFolderRows.map(\.id), [enabledID])
        XCTAssertEqual(missingRows.map(\.id), [missingID])
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
            policy: AppleShortcutPolicy(
                requiresConfirmation: false,
                allowsRunLink: false
            ),
            requestConfirmation: { confirmationCount += 1 },
            run: { immediateRunCount += 1 }
        )

        XCTAssertEqual(immediateRunCount, 1)
        XCTAssertEqual(confirmationCount, 1)
    }

    func testFolderNamesUseTheSelectedRuntimeLocale() {
        let names = ["Home", "Work"]

        XCTAssertEqual(
            AppleShortcutsSettingsFormatting.joinedFolderNames(
                names,
                locale: Locale(identifier: "en")
            ),
            "Home and Work"
        )
        XCTAssertEqual(
            AppleShortcutsSettingsFormatting.joinedFolderNames(
                names,
                locale: Locale(identifier: "zh-Hans")
            ),
            "Home和Work"
        )
        XCTAssertEqual(
            AppleShortcutsSettingsFormatting.joinedFolderNames(
                names,
                locale: Locale(identifier: "zh-Hant")
            ),
            "Home和Work"
        )
    }

    private func row(id: UUID, name: String, isMissing: Bool) -> AppleShortcutsDisplayRow {
        AppleShortcutsDisplayRow(id: id, name: name, item: nil, isMissing: isMissing)
    }
}
