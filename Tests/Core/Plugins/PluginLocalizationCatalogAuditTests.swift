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
        "plugin.management.hideFromDashboard",
        "plugin.management.hideFromFeaturePanelFormat",
        "plugin.management.hideFromFeaturePanel",
        "plugin.management.moveToBottom",
        "plugin.management.moveToTop",
        "plugin.management.showInFeaturePanelFormat",
        "plugin.management.showInDashboard",
        "plugin.management.showInFeaturePanel",
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

    private let pluginKitActionLocalizationKeys = [
        "action.error.failed",
        "action.error.invalidParameters",
        "action.error.unavailable",
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
                    validateFormatSpecifiers(
                        source: key,
                        entry: catalog[key],
                        key: "\(plugin.lastPathComponent).\(key)",
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

    func testPluginActionCatalogTitlesAreNotHardCodedInChinese() throws {
        let expression = try NSRegularExpression(
            pattern: #"ActionCatalogEntry\s*\([\s\S]{0,400}?title\s*:\s*\"[^\"]*[\p{Han}]"#
        )
        var failures: [String] = []

        for plugin in try pluginDirectories() {
            for sourceFile in try files(
                withExtension: "swift",
                in: plugin.appending(path: "Sources")
            ) {
                let source = try String(contentsOf: sourceFile, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                if expression.firstMatch(in: source, range: range) != nil {
                    failures.append(
                        "\(plugin.lastPathComponent)/\(sourceFile.lastPathComponent): action catalog titles must use plugin localization"
                    )
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testPluginActionDefinitionsDoNotExposeHardCodedChinese() throws {
        let patterns = [
            #"ActionDefinition\s*\([\s\S]{0,500}?\btitle\s*:\s*\"[^\"]*[\p{Han}]"#,
            #"ActionDefinition\s*\([\s\S]{0,700}?\bdescription\s*:\s*\"[^\"]*[\p{Han}]"#,
            #"ActionParameterDefinition\s*\([\s\S]{0,250}?\btitle\s*:\s*\"[^\"]*[\p{Han}]"#,
            #"ActionConfirmation\s*\([\s\S]{0,500}?(?:title|message|confirmButtonTitle)\s*:\s*\"[^\"]*[\p{Han}]"#,
            #"\.unavailable\s*\(\s*\"[^\"]*[\p{Han}]"#,
            #"\.failed\s*\(\s*message\s*:\s*\"[^\"]*[\p{Han}]"#,
        ].map { try! NSRegularExpression(pattern: $0) }
        var failures: [String] = []

        for plugin in try pluginDirectories() {
            for sourceFile in try files(
                withExtension: "swift",
                in: plugin.appending(path: "Sources")
            ) {
                let source = try String(contentsOf: sourceFile, encoding: .utf8)
                guard source.contains("ActionDefinition(") else { continue }
                let range = NSRange(source.startIndex..., in: source)
                if patterns.contains(where: { $0.firstMatch(in: source, range: range) != nil }) {
                    failures.append(
                        "\(plugin.lastPathComponent)/\(sourceFile.lastPathComponent): action definitions, parameters, confirmations, availability, and failures must use runtime localization"
                    )
                }
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

    func testPluginKitActionLocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "MacToolsPluginKit")
            .appending(path: "Resources")
            .appending(path: "Localizable.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        var failures: [String] = []
        for key in pluginKitActionLocalizationKeys {
            validate(key: key, in: strings, pluginName: "PluginKit Actions", failures: &failures)
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testFeatureUILocalizationKeysCoverAllSupportedLanguages() throws {
        let catalogURL = repositoryRoot
            .appending(path: "Sources")
            .appending(path: "Resources")
            .appending(path: "Localization")
            .appending(path: "FeatureUI.xcstrings")
        let catalog = try jsonObject(at: catalogURL)
        guard let strings = catalog["strings"] as? [String: [String: Any]] else {
            throw AuditError.invalidCatalog(catalogURL.path)
        }

        let sourceFiles = try files(
            withExtension: "swift",
            in: repositoryRoot.appending(path: "Sources")
        )
        let referencedKeys = try sourceFiles.reduce(into: Set<String>()) { result, url in
            result.formUnion(featureSourceLocalizationKeys(
                in: try String(contentsOf: url, encoding: .utf8)
            ))
        }

        var failures: [String] = []
        for key in referencedKeys.sorted() {
            validate(key: key, in: strings, pluginName: "Feature UI", failures: &failures)
            validateFormatSpecifiers(
                source: key,
                entry: strings[key],
                key: key,
                failures: &failures
            )
        }

        XCTAssertFalse(referencedKeys.isEmpty, "Feature UI: no localization keys were discovered")
        XCTAssertEqual(
            Set(strings.keys),
            referencedKeys,
            "FeatureUI.xcstrings must contain exactly the source-keyed strings used by FeatureL10n"
        )
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

    private func validateFormatSpecifiers(
        source: String,
        entry: [String: Any]?,
        key: String,
        failures: inout [String]
    ) {
        let expected = formatSpecifiers(in: source)
        guard !expected.isEmpty else { return }
        guard let localizations = entry?["localizations"] as? [String: Any] else { return }

        for language in supportedLanguages {
            guard
                let localization = localizations[language] as? [String: Any],
                let stringUnit = localization["stringUnit"] as? [String: Any],
                let value = stringUnit["value"] as? String
            else {
                continue
            }
            let actual = formatSpecifiers(in: value)
            if actual != expected {
                failures.append(
                    "Feature UI: \(key) has format specifiers \(actual) for \(language), expected \(expected)"
                )
            }
        }
    }

    private func formatSpecifiers(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@d]|%%"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }.sorted()
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
        var keys: Set<String> = Set(expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[keyRange])
        })
        keys.formUnion(pluginSourceLocalizationKeys(in: source))
        return keys
    }

    private func featureSourceLocalizationKeys(in source: String) -> Set<String> {
        sourceLocalizationKeys(
            in: source,
            pattern: #"FeatureL10n\.(?:string|format)\s*\(\s*"((?:\\.|[^"\\])*)""#
        )
    }

    private func pluginSourceLocalizationKeys(in source: String) -> Set<String> {
        sourceLocalizationKeys(
            in: source,
            pattern: #"(?<![A-Za-z])localized(?:Format)?\s*\(\s*"((?:\\.|[^"\\])*)""#
        )
    }

    private func sourceLocalizationKeys(in source: String, pattern: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return Set(expression.matches(in: source, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            let escapedValue = String(source[keyRange])
            let jsonString = "\"\(escapedValue)\""
            return (try? JSONDecoder().decode(String.self, from: Data(jsonString.utf8)))
                ?? escapedValue
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
