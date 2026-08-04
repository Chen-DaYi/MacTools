import Foundation
import XCTest
@testable import MacTools

final class PluginLocalizationCatalogAuditTests: XCTestCase {
    private var supportedLanguages: [String] {
        AppLanguagePreference.allCases
            .compactMap { $0.appleLanguagesOverride?.first }
            .sorted()
    }

    private let dynamicLocalizationKeys = [
        "PhysicalCleanMode": [
            "error.accessibilityRequired",
            "error.invalidExitShortcut",
        ],
    ]

    private let pluginManagementLocalizationKeys = [
        "plugin.management.active",
        "plugin.management.uninstall.confirmationMessage",
        "plugin.management.uninstall.confirmationTitle",
        "plugin.management.uninstall.confirmationPausedNotice",
        "plugin.management.uninstall.pauseConfirmation",
        "plugin.management.uninstall.resumeConfirmation",
        "plugin.management.viewMarketplace",
        "plugin.management.openSettings",
        "plugin.management.openSettingsForPlugin",
        "plugin.management.hideFromDashboardFormat",
        "plugin.management.hideFromFeaturePanelFormat",
        "plugin.management.showInFeaturePanelFormat",
        "plugin.management.showOnDashboardFormat",
        "plugin.capability.both",
        "plugin.capability.dashboard",
        "plugin.capability.featurePanel",
        "plugin.capability.settingsOnly",
        "plugin.capability.unknown",
        "plugin.marketplace.description",
    ]

    private let pluginLayoutSettingsLocalizationKeys = [
        "plugins.dashboard.description",
        "plugins.dashboard.empty.description",
        "plugins.dashboard.empty.title",
        "plugins.dashboard.hiddenSectionFormat",
        "plugins.dashboard.open",
        "plugins.dashboard.title",
        "plugins.featurePanel.description",
        "plugins.featurePanel.empty.description",
        "plugins.featurePanel.empty.title",
        "plugins.featurePanel.hiddenSectionFormat",
        "plugins.featurePanel.open",
        "plugins.featurePanel.title",
        "plugins.layout.restoreDefaultOrder",
        "plugins.sidebar.accessibilityLabel",
        "plugins.sidebar.dashboard",
        "plugins.sidebar.featurePanel",
        "plugins.sidebar.pluginsSection",
    ]

    private let settingsNavigationLocalizationKeys = [
        "navigation.back",
        "navigation.forward",
    ]

    private let appShortcutLocalizationKeys = [
        "shortcuts.openCommandPalette.description",
        "shortcuts.openCommandPalette.title",
    ]

    func testPluginStaticLocalizationKeysCoverAllSupportedLanguages() throws {
        var failures: [String] = []

        for plugin in try pluginDirectories() {
            let catalog = try loadCatalog(for: plugin)
            let sourceFiles = try files(withExtension: "swift", in: plugin.appending(path: "Sources"))

            for sourceFile in sourceFiles {
                let source = try String(contentsOf: sourceFile, encoding: .utf8)
                for key in staticLocalizationKeys(in: source) {
                    validate(
                        key: key,
                        in: catalog,
                        pluginName: plugin.lastPathComponent,
                        failures: &failures
                    )
                }
            }

            for key in dynamicLocalizationKeys[plugin.lastPathComponent, default: []] {
                validate(
                    key: key,
                    in: catalog,
                    pluginName: plugin.lastPathComponent,
                    failures: &failures
                )
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testKeepAwakeCatalogContainsOnlyReferencedKeys() throws {
        let plugin = repositoryRoot.appending(path: "Plugins/KeepAwake")
        let catalog = try loadCatalog(for: plugin)
        let sourceFiles = try files(withExtension: "swift", in: plugin.appending(path: "Sources"))
        var referencedKeys = Set(dynamicLocalizationKeys["KeepAwake", default: []])

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            referencedKeys.formUnion(staticLocalizationKeys(in: source))
        }

        let unusedKeys = Set(catalog.keys).subtracting(referencedKeys).sorted()
        XCTAssertTrue(
            unusedKeys.isEmpty,
            "KeepAwake contains unreferenced localization keys:\n\(unusedKeys.joined(separator: "\n"))"
        )
    }

    func testKeepAwakeFallbacksMatchSourceLanguageCatalogValues() throws {
        let plugin = repositoryRoot.appending(path: "Plugins/KeepAwake")
        let catalog = try loadCatalog(for: plugin)
        let sourceFiles = try files(withExtension: "swift", in: plugin.appending(path: "Sources"))
        var failures: [String] = []

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            for fallback in staticLocalizationFallbacks(in: source) {
                guard let catalogValue = sourceLanguageValue(for: fallback.key, in: catalog) else {
                    continue
                }
                if fallback.value != catalogValue {
                    failures.append(
                        "\(sourceFile.lastPathComponent): \(fallback.key) fallback \"\(fallback.value)\" does not match zh-Hans catalog value \"\(catalogValue)\""
                    )
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPluginManifestsCoverAllSupportedLanguages() throws {
        var failures: [String] = []

        for plugin in try pluginDirectories() {
            let manifestURL = plugin.appending(path: "plugin.json")
            let manifest = try jsonObject(at: manifestURL)
            let metadata = manifest["localizedMetadata"] as? [String: Any]
            for language in supportedLanguages {
                guard let localizedMetadata = metadata?[language] as? [String: Any] else {
                    failures.append("\(plugin.lastPathComponent): plugin.json is missing localizedMetadata.\(language)")
                    continue
                }

                for field in ["displayName", "summary"] {
                    guard let value = localizedMetadata[field] as? String, !value.isEmpty else {
                        failures.append("\(plugin.lastPathComponent): plugin.json is missing localizedMetadata.\(language).\(field)")
                        continue
                    }
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testUnifiedSearchPluginProvidersRequireFirstCompatibleHostVersion() throws {
        let expectedMinimumHostVersion = "1.1.5"
        let pluginNames = [
            "DisplayBrightness",
            "DisplaySleep",
            "KeepAwake",
            "LockScreen",
        ]

        for pluginName in pluginNames {
            let manifestURL = repositoryRoot
                .appending(path: "Plugins")
                .appending(path: pluginName)
                .appending(path: "plugin.json")
            let manifest = try jsonObject(at: manifestURL)

            let minimumHostVersion = try XCTUnwrap(manifest["minHostVersion"] as? String)
            XCTAssertTrue(
                PluginVersionComparator.isVersion(
                    minimumHostVersion,
                    atLeast: expectedMinimumHostVersion
                ),
                "\(pluginName) must not be published to hosts that predate unified-search PluginKit symbols"
            )
        }
    }

    func testPluginManagementLocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Plugins.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        var failures: [String] = []
        for key in pluginManagementLocalizationKeys {
            validate(key: key, in: strings, pluginName: "Plugin Management", failures: &failures)
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPluginLayoutSettingsLocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Settings.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        var failures: [String] = []
        for key in pluginLayoutSettingsLocalizationKeys {
            validate(key: key, in: strings, pluginName: "Plugin Layout Settings", failures: &failures)
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSettingsNavigationLocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Settings.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        var failures: [String] = []
        for key in settingsNavigationLocalizationKeys {
            validate(key: key, in: strings, pluginName: "Settings Navigation", failures: &failures)
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAppShortcutLocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Settings.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        var failures: [String] = []
        for key in appShortcutLocalizationKeys {
            validate(key: key, in: strings, pluginName: "App Shortcuts", failures: &failures)
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testUnifiedSearchLocalizationKeysCoverAllSupportedLanguages() throws {
        let localizationDirectory = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
        let catalogURL = localizationDirectory.appending(path: "Search.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        let appDirectory = repositoryRoot.appending(path: "Sources").appending(path: "App")
        let sourceNames = [
            "AppHostCommands.swift",
            "MacToolsSearch.swift",
            "SettingsView.swift",
            "UnifiedSearchPaletteView.swift",
        ]
        let keys = try sourceNames.reduce(into: Set<String>()) { result, name in
            let source = try String(
                contentsOf: appDirectory.appending(path: name),
                encoding: .utf8
            )
            result.formUnion(staticLocalizationKeys(in: source).filter { $0.hasPrefix("search.") })
        }

        var failures: [String] = []
        for key in keys.sorted() {
            validate(
                key: key,
                in: strings,
                pluginName: "Unified Search",
                failures: &failures
            )
        }

        XCTAssertFalse(keys.isEmpty, "Unified Search: no static localization keys were discovered")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testUnifiedSearchResultCountUsesRequiredPluralForms() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Search.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let entry = try XCTUnwrap(strings["search.resultCountFormat"])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let expectedCategories: [String: Set<String>] = [
            "ar": ["zero", "one", "two", "few", "many", "other"],
            "de": ["one", "other"],
            "en": ["one", "other"],
            "es": ["one", "other"],
            "fr": ["one", "other"],
            "ja": ["other"],
            "ko": ["other"],
            "pt": ["one", "other"],
            "ru": ["one", "few", "many", "other"],
            "zh-Hans": ["other"],
            "zh-Hant": ["other"],
        ]

        for (language, categories) in expectedCategories {
            let localization = try XCTUnwrap(localizations[language] as? [String: Any])
            let variations = try XCTUnwrap(localization["variations"] as? [String: Any])
            let plural = try XCTUnwrap(variations["plural"] as? [String: Any])
            XCTAssertTrue(
                categories.isSubset(of: Set(plural.keys)),
                "\(language) is missing plural categories \(categories.subtracting(plural.keys))"
            )
        }
    }

    func testUnifiedSearchVisibilityFormatsPreserveBothArguments() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "Search.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let keys = [
            "search.command.pluginVisibility.show.titleFormat",
            "search.command.pluginVisibility.show.descriptionFormat",
            "search.command.pluginVisibility.hide.titleFormat",
            "search.command.pluginVisibility.hide.descriptionFormat",
        ]

        for key in keys {
            let entry = try XCTUnwrap(strings[key], "Missing localization key \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            for language in supportedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "Missing \(language) localization for \(key)"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "Missing string unit for \(key) in \(language)"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "Missing value for \(key) in \(language)"
                )
                XCTAssertTrue(value.contains("%1$@"), "\(key) in \(language) is missing %1$@")
                XCTAssertTrue(value.contains("%2$@"), "\(key) in \(language) is missing %2$@")
            }
        }
    }

    private func validate(
        key: String,
        in catalog: [String: [String: Any]],
        pluginName: String,
        failures: inout [String]
    ) {
        guard let entry = catalog[key] else {
            failures.append("\(pluginName): missing localization key \(key)")
            return
        }

        let localizations = entry["localizations"] as? [String: Any]
        for language in supportedLanguages {
            guard
                let localization = localizations?[language],
                containsTranslatedValue(in: localization)
            else {
                failures.append("\(pluginName): localization key \(key) is missing a translated value for \(language)")
                continue
            }
        }
    }

    private func containsTranslatedValue(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if
                let stringUnit = dictionary["stringUnit"] as? [String: Any],
                let translatedValue = stringUnit["value"] as? String,
                !translatedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }

            return dictionary.values.contains(where: containsTranslatedValue)
        }

        if let array = value as? [Any] {
            return array.contains(where: containsTranslatedValue)
        }

        return false
    }

    private func pluginDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: repositoryRoot.appending(path: "Plugins"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && FileManager.default.fileExists(atPath: url.appending(path: "plugin.json").path)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadCatalog(for plugin: URL) throws -> [String: [String: Any]] {
        let resourceDirectory = plugin.appending(path: "Resources")
        let catalogs = try files(withExtension: "xcstrings", in: resourceDirectory)
        var strings: [String: [String: Any]] = [:]

        if catalogs.isEmpty {
            throw AuditError.missingCatalog(plugin.lastPathComponent)
        }

        for catalogURL in catalogs {
            let catalog = try jsonObject(at: catalogURL)
            guard let catalogStrings = catalog["strings"] as? [String: [String: Any]] else {
                throw AuditError.invalidCatalog(catalogURL.path)
            }
            strings.merge(catalogStrings) { _, new in new }
        }

        return strings
    }

    private func staticLocalizationKeys(in source: String) -> Set<String> {
        let expression = try! NSRegularExpression(
            pattern: #"(?:\b(?:self\.)?[A-Za-z_]\w*|PluginLocalization\([^\n]*\))\.(?:string|format|search|searchFormat|searchPluralFormat)\s*\(\s*\"([^\"]+)\"\s*,\s*defaultValue\s*:"#
        )
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[keyRange])
        })
    }

    private func staticLocalizationFallbacks(in source: String) -> [(key: String, value: String)] {
        let expression = try! NSRegularExpression(
            pattern: #"(?:\b(?:self\.)?[A-Za-z_]\w*|PluginLocalization\([^\n]*\))\.(?:string|format)\s*\(\s*\"([^\"]+)\"\s*,\s*defaultValue\s*:\s*\"((?:\\.|[^\"\\])*)\""#
        )
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard
                let keyRange = Range(match.range(at: 1), in: source),
                let valueRange = Range(match.range(at: 2), in: source)
            else {
                return nil
            }

            let escapedValue = String(source[valueRange])
            let jsonString = "\"\(escapedValue)\""
            let value = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? String
            return (String(source[keyRange]), value ?? escapedValue)
        }
    }

    private func sourceLanguageValue(
        for key: String,
        in catalog: [String: [String: Any]]
    ) -> String? {
        guard
            let localizations = catalog[key]?["localizations"] as? [String: Any],
            let sourceLocalization = localizations["zh-Hans"] as? [String: Any],
            let stringUnit = sourceLocalization["stringUnit"] as? [String: Any]
        else {
            return nil
        }

        return stringUnit["value"] as? String
    }

    private func files(withExtension fileExtension: String, in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        return try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".\(fileExtension)") }
            .map { directory.appending(path: $0) }
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw AuditError.invalidCatalog(url.path)
        }
        return dictionary
    }

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private enum AuditError: LocalizedError {
    case invalidCatalog(String)
    case missingCatalog(String)

    var errorDescription: String? {
        switch self {
        case let .invalidCatalog(path):
            "Invalid string catalog: \(path)"
        case let .missingCatalog(pluginName):
            "Missing string catalog for plugin: \(pluginName)"
        }
    }
}
