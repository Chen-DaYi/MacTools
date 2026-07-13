import Foundation
import XCTest
@testable import MacTools

final class PreferencesBackupLocalizationTests: XCTestCase {
    private let supportedLanguages = [
            "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh-Hans", "zh-Hant"
        ]

    func testCompiledCatalogContainsEverySupportedLanguageForEveryBackupString() throws {
        let resourcesURL = try XCTUnwrap(Bundle.main.resourceURL)

        for language in supportedLanguages {
            let stringsURL = resourcesURL
                .appending(path: "\(language).lproj/PreferencesBackup.strings")
            let strings = try XCTUnwrap(
                NSDictionary(contentsOf: stringsURL) as? [String: String],
                "Missing compiled PreferencesBackup strings for \(language)"
            )

            for key in backupStringKeys {
                XCTAssertNotNil(strings[key], "\(key) must be compiled for \(language)")
            }
        }
    }

    func testCompiledSettingsCatalogContainsCancelForEverySupportedLanguage() throws {
        let resourcesURL = try XCTUnwrap(Bundle.main.resourceURL)

        for language in supportedLanguages {
            let stringsURL = resourcesURL
                .appending(path: "\(language).lproj/Settings.strings")
            let strings = try XCTUnwrap(
                NSDictionary(contentsOf: stringsURL) as? [String: String],
                "Missing compiled Settings strings for \(language)"
            )

            XCTAssertNotNil(strings["common.cancel"], "common.cancel must be compiled for \(language)")
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
            "preferencesBackup.preview.installablePlugins",
            "preferencesBackup.preview.installablePluginsDescription",
            "preferencesBackup.preview.installAndImport",
            "preferencesBackup.preview.plugins",
            "preferencesBackup.preview.pluginsCount",
            "preferencesBackup.preview.replaceNotice",
            "preferencesBackup.preview.shortcuts",
            "preferencesBackup.preview.shortcutsCount",
            "preferencesBackup.preview.skipped",
            "preferencesBackup.preview.title",
            "preferencesBackup.title"
        ]
    }
}
