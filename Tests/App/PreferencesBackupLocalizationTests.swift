import Foundation
import XCTest
@testable import MacTools

final class PreferencesBackupLocalizationTests: XCTestCase {
    func testCatalogContainsEverySupportedLanguageForEveryBackupString() throws {
        let catalog = try loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let supportedLanguages: Set<String> = [
            "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh-Hans", "zh-Hant"
        ]

        for key in backupStringKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key) in PreferencesBackup.xcstrings")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])

            XCTAssertEqual(
                Set(localizations.keys),
                supportedLanguages,
                "\(key) must be translated for every supported language"
            )
        }
    }

    private var backupStringKeys: [String] {
        [
            "general.section.preferencesBackup",
            "preferencesBackup.alert.title",
            "preferencesBackup.description",
            "preferencesBackup.error.invalidApplicationPreferences",
            "preferencesBackup.error.unsupportedFormat",
            "preferencesBackup.export",
            "preferencesBackup.export.prompt",
            "preferencesBackup.exported",
            "preferencesBackup.import",
            "preferencesBackup.import.prompt",
            "preferencesBackup.imported",
            "preferencesBackup.preview.application",
            "preferencesBackup.preview.applicationSummary",
            "preferencesBackup.preview.confirm",
            "preferencesBackup.preview.description",
            "preferencesBackup.preview.plugins",
            "preferencesBackup.preview.pluginsCount",
            "preferencesBackup.preview.shortcuts",
            "preferencesBackup.preview.shortcutsCount",
            "preferencesBackup.preview.skipped",
            "preferencesBackup.preview.title",
            "preferencesBackup.title"
        ]
    }

    private func loadCatalog() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appending(path: "Sources/Resources/Localization/PreferencesBackup.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
