import Foundation
import XCTest
@testable import TranslatorPlugin

final class AutomaticLanguageSelectorTests: XCTestCase {
    func testEnglishSourceTargetsFirstPreferredChinese() {
        let selector = AutomaticLanguageSelector(
            detector: StubLanguageDetector(language: .english),
            preferredPair: TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )

        let selection = selector.select(text: "Hello")

        XCTAssertEqual(selection.source, .english)
        XCTAssertEqual(selection.target, .simplifiedChinese)
        XCTAssertFalse(selection.sourceIsAutomatic)
        XCTAssertEqual(selection.sourceDisplayName, "英语")
    }

    func testFirstPreferredSourceTargetsSecondPreferredEnglish() {
        let selector = AutomaticLanguageSelector(
            detector: StubLanguageDetector(language: .simplifiedChinese),
            preferredPair: TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )

        let selection = selector.select(text: "你好")

        XCTAssertEqual(selection.source, .simplifiedChinese)
        XCTAssertEqual(selection.target, .english)
        XCTAssertFalse(selection.sourceIsAutomatic)
    }

    func testUnknownSourceUsesAutomaticSourceAndFirstPreferredTarget() {
        let selector = AutomaticLanguageSelector(
            detector: StubLanguageDetector(language: nil),
            preferredPair: TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )

        let selection = selector.select(text: "123")

        XCTAssertNil(selection.source)
        XCTAssertEqual(selection.target, .simplifiedChinese)
        XCTAssertTrue(selection.sourceIsAutomatic)
        XCTAssertEqual(selection.sourceDisplayName, "自动检测")
    }
}

private struct StubLanguageDetector: LanguageDetecting {
    let language: TranslatorLanguage?

    func detect(_ text: String) -> TranslatorLanguage? {
        language
    }
}
