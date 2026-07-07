import Foundation
import XCTest
@testable import TranslatorPlugin

final class TranslationPromptRendererTests: XCTestCase {
    func testRendersAllPlaceholdersExactly() throws {
        let renderer = TranslationPromptRenderer(
            template: "Source={{source_language}}\nTarget={{target_language}}\nText={{text}}"
        )

        let prompt = try renderer.render(
            text: "Hello {{target_language}}",
            sourceLanguageName: "English",
            targetLanguageName: "Simplified Chinese"
        )

        XCTAssertEqual(
            prompt,
            "Source=English\nTarget=Simplified Chinese\nText=Hello {{target_language}}"
        )
    }

    func testMissingTextPlaceholderThrowsLocalizedMessage() {
        let renderer = TranslationPromptRenderer(
            template: "Source={{source_language}}\nTarget={{target_language}}"
        )

        XCTAssertThrowsError(
            try renderer.render(
                text: "Hello",
                sourceLanguageName: "English",
                targetLanguageName: "Simplified Chinese"
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "提示词必须包含 {{text}}。")
        }
    }
}
