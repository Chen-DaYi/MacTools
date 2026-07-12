import XCTest
@testable import MacTools

final class AppLanguagePreferenceTests: XCTestCase {
    func testAllCasesIncludeSupportedFixedLanguages() {
        XCTAssertEqual(
            AppLanguagePreference.allCases.map(\.rawValue),
            [
                "system",
                "zh-Hans",
                "zh-Hant",
                "en",
                "es",
                "fr",
                "ru",
                "pt",
                "de",
                "ja",
                "ko",
                "ar"
            ]
        )
    }

    func testAppleLanguagesOverrideMatchesSelectedLanguage() {
        let overrides = Dictionary(
            uniqueKeysWithValues: AppLanguagePreference.allCases.map {
                ($0.rawValue, $0.appleLanguagesOverride)
            }
        )

        XCTAssertNil(overrides["system"]!)
        XCTAssertEqual(overrides["zh-Hans"]!, ["zh-Hans"])
        XCTAssertEqual(overrides["zh-Hant"]!, ["zh-Hant"])
        XCTAssertEqual(overrides["en"]!, ["en"])
        XCTAssertEqual(overrides["es"]!, ["es"])
        XCTAssertEqual(overrides["fr"]!, ["fr"])
        XCTAssertEqual(overrides["ru"]!, ["ru"])
        XCTAssertEqual(overrides["pt"]!, ["pt"])
        XCTAssertEqual(overrides["de"]!, ["de"])
        XCTAssertEqual(overrides["ja"]!, ["ja"])
        XCTAssertEqual(overrides["ko"]!, ["ko"])
        XCTAssertEqual(overrides["ar"]!, ["ar"])
    }

    func testPickerTitleIncludesSystemLanguageNameForSystemOption() {
        let title = AppLanguagePreference.system.pickerTitle(systemLanguageIdentifier: "en")

        XCTAssertTrue(title.contains("English"))
        XCTAssertTrue(title.hasPrefix(AppLanguagePreference.system.title))
    }

    func testPickerTitleCombinesSystemAndNativeLanguageNames() {
        let title = AppLanguagePreference.de.pickerTitle(systemLanguageIdentifier: "en")

        XCTAssertTrue(title.contains("German"))
        XCTAssertTrue(title.hasSuffix("/ Deutsch"))
    }

    func testPickerTitlesKeepTheNativeNameOfEveryFixedLanguage() {
        let expectedNativeNames: [(AppLanguagePreference, String)] = [
            (.zhHans, "简体中文"),
            (.zhHant, "繁體中文"),
            (.en, "English"),
            (.es, "Español"),
            (.fr, "Français"),
            (.ru, "Русский"),
            (.pt, "Português (Brasil)"),
            (.de, "Deutsch"),
            (.ja, "日本語"),
            (.ko, "한국어"),
            (.ar, "العربية")
        ]

        for (preference, nativeName) in expectedNativeNames {
            let title = preference.pickerTitle(systemLanguageIdentifier: "en")
            XCTAssertTrue(
                title == nativeName || title.hasSuffix("/ \(nativeName)"),
                "Expected \(preference.rawValue) to retain \(nativeName), got \(title)"
            )
        }
    }

    func testPickerTitleKeepsNativeNameWhenItMatchesSystemLanguageName() {
        XCTAssertEqual(
            AppLanguagePreference.en.pickerTitle(systemLanguageIdentifier: "en"),
            "English"
        )
    }
}
