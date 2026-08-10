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
