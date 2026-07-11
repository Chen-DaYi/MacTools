import Foundation
import XCTest
@testable import MacTools

final class PreferencesBackupLocalizationTests: XCTestCase {
    func testCatalogContainsEverySupportedLanguageForEveryBackupString() throws {
        let supportedLanguages: Set<String> = [
            "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh-Hans", "zh-Hant"
        ]

        try assertTranslations(
            in: "PreferencesBackup",
            keys: backupStringKeys,
            supportedLanguages: supportedLanguages
        )
        try assertTranslations(
            in: "PreferencesBackupImport",
            keys: backupImportStringKeys,
            supportedLanguages: supportedLanguages
        )
    }

    private var backupImportStringKeys: [String] {
        [
            "preferencesBackup.preview.installablePlugins",
            "preferencesBackup.preview.installablePluginsDescription",
            "preferencesBackup.preview.installAndImport"
        ]
    }

    private func assertTranslations(
        in catalogName: String,
        keys: [String],
        supportedLanguages: Set<String>
    ) throws {
        let catalog = try loadCatalog(named: catalogName)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key) in \(catalogName).xcstrings")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])

            XCTAssertEqual(Set(localizations.keys), supportedLanguages, "\(key) must be translated for every supported language")
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

    private func loadCatalog(named name: String) throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appending(path: "Sources/Resources/Localization/\(name).xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
