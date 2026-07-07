import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorPanelPresentationTests: XCTestCase {
    func testMissingSelectionUsesCompactEmptySourceAndTipCard() {
        let snapshot = TranslatorPanelSnapshot(
            phase: .error(.missingSelection),
            sourceText: nil,
            languageSelection: nil,
            translation: nil,
            providerResults: [
                TranslatorProviderResult(
                    id: "openai",
                    providerTitle: "OpenAI 翻译",
                    phase: .waiting,
                    translation: nil,
                    errorMessage: nil
                ),
                TranslatorProviderResult(
                    id: "deepseek",
                    providerTitle: "DeepSeek 翻译",
                    phase: .waiting,
                    translation: nil,
                    errorMessage: nil
                ),
                TranslatorProviderResult(
                    id: "fireworks",
                    providerTitle: "Fireworks",
                    phase: .waiting,
                    translation: nil,
                    errorMessage: nil
                ),
            ],
            errorMessage: "未找到选中文本",
            querySource: .selectedText,
            captureStage: nil
        )

        let presentation = TranslatorPanelPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.sourceText, "")
        XCTAssertTrue(presentation.usesSourceCaretPlaceholder)
        XCTAssertEqual(presentation.sourceLanguageTitle, "自动检测")
        XCTAssertEqual(presentation.targetLanguageTitle, "自动选择")
        XCTAssertEqual(presentation.tip?.title, "提示")
        XCTAssertEqual(presentation.tip?.message, "划词翻译没有获取到文本")
        XCTAssertEqual(presentation.tip?.actionTitle, "如何解决")
        XCTAssertEqual(presentation.providerRows.map(\.title), ["OpenAI 翻译", "DeepSeek 翻译", "Fireworks"])
        XCTAssertTrue(presentation.providerRows.allSatisfy { !$0.isExpanded })
    }

    func testSuccessExpandsFirstProviderWithTranslatedText() {
        let selection = TranslatorLanguageSelection(source: .english, target: .simplifiedChinese)
        let firstResult = TranslationResult(
            providerTitle: "OpenAI 翻译",
            text: "你好",
            sourceText: "hello",
            languageSelection: selection
        )
        let secondResult = TranslationResult(
            providerTitle: "DeepSeek 翻译",
            text: "您好",
            sourceText: "hello",
            languageSelection: selection
        )
        let snapshot = TranslatorPanelSnapshot(
            phase: .success,
            sourceText: "hello",
            languageSelection: selection,
            translation: firstResult,
            providerResults: [
                TranslatorProviderResult(
                    id: "openai",
                    providerTitle: "OpenAI 翻译",
                    phase: .success,
                    translation: firstResult,
                    errorMessage: nil
                ),
                TranslatorProviderResult(
                    id: "deepseek",
                    providerTitle: "DeepSeek 翻译",
                    phase: .success,
                    translation: secondResult,
                    errorMessage: nil
                ),
            ],
            errorMessage: nil,
            querySource: .selectedText,
            captureStage: nil
        )

        let presentation = TranslatorPanelPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.sourceText, "hello")
        XCTAssertFalse(presentation.usesSourceCaretPlaceholder)
        XCTAssertNil(presentation.tip)
        XCTAssertEqual(presentation.sourceLanguageTitle, "英语")
        XCTAssertEqual(presentation.targetLanguageTitle, "简体中文")
        XCTAssertEqual(presentation.providerRows.map(\.title), ["OpenAI 翻译", "DeepSeek 翻译"])
        XCTAssertEqual(presentation.providerRows[0].bodyText, "你好")
        XCTAssertTrue(presentation.providerRows[0].isExpanded)
        XCTAssertEqual(presentation.providerRows[1].bodyText, "您好")
        XCTAssertFalse(presentation.providerRows[1].isExpanded)
    }
}
