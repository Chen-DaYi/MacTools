import Carbon
import XCTest
@testable import TranslatorPlugin

final class TranslatorScreenshotModelsTests: XCTestCase {
    func testScreenshotTranslationConstantsAreStable() {
        XCTAssertEqual(TranslatorConstants.PermissionID.screenRecording, "screen-recording")
        XCTAssertEqual(TranslatorConstants.ShortcutID.screenshotTranslation, "translator.screenshot-translation")
        XCTAssertEqual(TranslatorConstants.ActionID.screenshotTranslation, "screenshot-translation")
    }

    func testScreenshotTranslationUsesOptionSByDefault() {
        let binding = TranslatorConstants.Defaults.screenshotTranslationShortcut

        XCTAssertEqual(binding.keyCode, UInt16(kVK_ANSI_S))
        XCTAssertEqual(binding.modifiers, [.option])
    }

    func testTranslatorQuerySourceDistinguishesSelectionAndScreenshot() {
        XCTAssertEqual(TranslatorQuerySource.selectedText.sourceTitle, "selectedText")
        XCTAssertEqual(TranslatorQuerySource.screenshot.sourceTitle, "screenshot")
    }

    func testCaptureStageDistinguishesSelectedTextScreenshotRegionAndOCR() {
        XCTAssertEqual(TranslatorCaptureStage.selectedText.placeholderKey, "panel.sourcePlaceholder.capturing")
        XCTAssertEqual(TranslatorCaptureStage.screenshotRegion.placeholderKey, "panel.sourcePlaceholder.screenshotRegion")
        XCTAssertEqual(TranslatorCaptureStage.ocr.placeholderKey, "panel.sourcePlaceholder.ocr")
    }
}
