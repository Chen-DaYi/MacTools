import XCTest
@testable import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginRuntimeLocalizationTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference(originalPreference)
    }

    override func tearDown() {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testFixedPreferenceOverridesProcessPreferredLanguages() {
        setRuntimePreference("ar")

        XCTAssertEqual(PluginRuntimeLocalization.preferredLanguages, ["ar"])
        XCTAssertEqual(PluginRuntimeLocalization.locale.language.languageCode?.identifier, "ar")
    }

    func testFixedPreferenceThenSystemUsesTheSystemLanguageSnapshot() {
        let source = makeLocaleSource(
            systemLanguages: ["en-GB"],
            currentLocale: Locale(identifier: "en_DE@calendar=gregorian")
        )

        source.setPreference("fr")
        XCTAssertEqual(source.preferredLanguages, ["fr"])
        XCTAssertEqual(source.locale.language.languageCode?.identifier, "fr")
        XCTAssertEqual(source.locale.region?.identifier, "DE")

        source.setPreference("system")
        XCTAssertEqual(source.preferredLanguages, ["en-GB"])
        XCTAssertEqual(source.locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(source.locale.region?.identifier, "DE")
    }

    func testFixedLanguageKeepsTheCurrentLocaleFormatSettings() {
        let source = makeLocaleSource(
            systemLanguages: ["en"],
            currentLocale: Locale(identifier: "en_DE@calendar=japanese")
        )

        source.setPreference("ja")

        XCTAssertEqual(source.locale.language.languageCode?.identifier, "ja")
        XCTAssertEqual(source.locale.region?.identifier, "DE")
        XCTAssertEqual(source.locale.calendar.identifier, .japanese)
    }

    func testChineseRegionUsesSimplifiedChineseResourceFallback() {
        XCTAssertEqual(
            PluginRuntimeLocalization.candidateLanguageIdentifiers(for: "zh-Hans-CN"),
            ["zh-Hans-CN", "zh-Hans", "zh"]
        )
    }

    func testStringLookupChangesLanguageWithoutRecreatingBundle() throws {
        let bundleURL = try makeLocalizedTestBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        setRuntimePreference("en")
        XCTAssertEqual(
            PluginRuntimeLocalization.string(
                "menu.title",
                defaultValue: "Fallback",
                table: "Settings",
                bundle: bundle
            ),
            "Menu Bar Icon"
        )

        setRuntimePreference("zh-Hans")
        XCTAssertEqual(
            PluginRuntimeLocalization.string(
                "menu.title",
                defaultValue: "Fallback",
                table: "Settings",
                bundle: bundle
            ),
            "菜单栏图标"
        )
    }

    func testPrimaryPanelButtonTitleProviderIsReadOnEveryAccess() {
        var title = "English"
        let descriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: { title }
        )

        XCTAssertEqual(descriptor.buttonTitle, "English")
        title = "中文"
        XCTAssertEqual(descriptor.buttonTitle, "中文")
    }

    func testMissingSelectedLanguageStringFallsBackToBaseLanguage() throws {
        let bundleURL = try makeLocalizedTestBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        setRuntimePreference("zh-Hans")

        XCTAssertEqual(
            PluginRuntimeLocalization.string(
                "fallback.title",
                defaultValue: "Fallback",
                table: "Settings",
                bundle: bundle
            ),
            "Base Language"
        )
    }

    func testMissingAllTranslationsFallsBackToTheCallerDefault() throws {
        let bundleURL = try makeLocalizedTestBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        setRuntimePreference("fr")

        XCTAssertEqual(
            PluginRuntimeLocalization.string(
                "missing.title",
                defaultValue: "Caller Default",
                table: "Settings",
                bundle: bundle
            ),
            "Caller Default"
        )
    }

    func testAppearanceLabelsFollowTheRuntimeLanguage() {
        setRuntimePreference("en")
        XCTAssertEqual(
            AppAppearancePreference.allCases.map(\.title),
            ["Automatic", "Dark", "Light"]
        )

        setRuntimePreference("zh-Hans")
        XCTAssertEqual(
            AppAppearancePreference.allCases.map(\.title),
            ["自动", "深色", "浅色"]
        )
    }

    func testWindowAndMenuBarTitlesFollowTwoRuntimeSwitches() {
        setRuntimePreference("en")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "Settings")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "Components Panel")
        XCTAssertEqual(MenuBarPanelTab.features.accessibilityTitle, "Features Panel")

        setRuntimePreference("zh-Hans")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "设置")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "组件面板")
        XCTAssertEqual(MenuBarPanelTab.features.accessibilityTitle, "功能面板")

        setRuntimePreference("en")
        XCTAssertEqual(AppWindowRouter.settingsWindowTitle, "Settings")
        XCTAssertEqual(MenuBarPanelTab.components.accessibilityTitle, "Components Panel")
    }

    private func makeLocalizedTestBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("Test.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        for (language, value) in [("en", "Menu Bar Icon"), ("zh-Hans", "菜单栏图标")] {
            let lprojURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: true)
            try "\"menu.title\" = \"\(value)\";\n".write(
                to: lprojURL.appendingPathComponent("Settings.strings"),
                atomically: true,
                encoding: .utf8
            )
        }

        let englishStrings = bundleURL
            .appendingPathComponent("en.lproj", isDirectory: true)
            .appendingPathComponent("Settings.strings")
        let existingStrings = try String(contentsOf: englishStrings, encoding: .utf8)
        try (existingStrings + "\"fallback.title\" = \"Base Language\";\n").write(
            to: englishStrings,
            atomically: true,
            encoding: .utf8
        )

        return bundleURL
    }

    private func setRuntimePreference(_ preference: String?) {
        if let preference {
            UserDefaults.standard.set(preference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        PluginRuntimeLocalization.source.setPreference(preference)
    }

    private func makeLocaleSource(
        systemLanguages: [String],
        currentLocale: Locale
    ) -> PluginRuntimeLocaleSource {
        let suiteName = "PluginRuntimeLocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PluginRuntimeLocaleSource(
            userDefaults: defaults,
            systemPreferredLanguages: { systemLanguages },
            currentLocale: { currentLocale }
        )
    }
}
