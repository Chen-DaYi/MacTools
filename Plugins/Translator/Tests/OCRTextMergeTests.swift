import Foundation
import XCTest
@testable import TranslatorPlugin

final class OCRTextMergeTests: XCTestCase {
    func testMergesLatinWordsOnSameLineWithSpaces() {
        let lines = [
            OCRRecognizedLine(text: "World", boundingBox: CGRect(x: 0.30, y: 0.80, width: 0.18, height: 0.08), confidence: 0.90),
            OCRRecognizedLine(text: "Hello", boundingBox: CGRect(x: 0.10, y: 0.81, width: 0.17, height: 0.08), confidence: 0.92),
        ]

        XCTAssertEqual(OCRTextMerge.merge(lines), "Hello World")
    }

    func testMergesCJKFragmentsOnSameLineWithoutSpaces() {
        let lines = [
            OCRRecognizedLine(text: "世界", boundingBox: CGRect(x: 0.22, y: 0.70, width: 0.12, height: 0.08), confidence: 0.90),
            OCRRecognizedLine(text: "你好", boundingBox: CGRect(x: 0.10, y: 0.70, width: 0.12, height: 0.08), confidence: 0.91),
        ]

        XCTAssertEqual(OCRTextMerge.merge(lines), "你好世界")
    }

    func testSortsRowsFromTopToBottom() {
        let lines = [
            OCRRecognizedLine(text: "second row", boundingBox: CGRect(x: 0.10, y: 0.45, width: 0.30, height: 0.07), confidence: 0.90),
            OCRRecognizedLine(text: "first row", boundingBox: CGRect(x: 0.10, y: 0.80, width: 0.28, height: 0.07), confidence: 0.90),
        ]

        XCTAssertEqual(OCRTextMerge.merge(lines), "first row\nsecond row")
    }

    func testTrimsBlankTextAndCollapsesWhitespace() {
        let lines = [
            OCRRecognizedLine(text: "  Hello   ", boundingBox: CGRect(x: 0.10, y: 0.80, width: 0.20, height: 0.07), confidence: 0.90),
            OCRRecognizedLine(text: "   ", boundingBox: CGRect(x: 0.32, y: 0.80, width: 0.04, height: 0.07), confidence: 0.90),
            OCRRecognizedLine(text: "World", boundingBox: CGRect(x: 0.38, y: 0.80, width: 0.18, height: 0.07), confidence: 0.90),
        ]

        XCTAssertEqual(OCRTextMerge.merge(lines), "Hello World")
    }
}
