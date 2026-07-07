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
}
