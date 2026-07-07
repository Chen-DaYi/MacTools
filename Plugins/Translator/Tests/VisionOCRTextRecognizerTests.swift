import AppKit
import XCTest
@testable import TranslatorPlugin

final class VisionOCRTextRecognizerTests: XCTestCase {
    func testEmptyImageThrowsInvalidImage() async {
        let recognizer = VisionOCRTextRecognizer()
        let image = NSImage(size: .zero)

        do {
            _ = try await recognizer.recognizeText(in: image)
            XCTFail("Expected invalid image error")
        } catch {
            XCTAssertEqual(error as? OCRTextRecognitionError, .invalidImage)
        }
    }

    func testEmptyRecognitionResultIsDetectable() {
        let result = OCRTextRecognitionResult(text: "  \n ", lines: [])

        XCTAssertTrue(result.isEmpty)
    }
}
