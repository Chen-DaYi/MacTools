import Foundation
import XCTest
@testable import TranslatorPlugin

final class AccessibilitySelectedTextCaptureTests: XCTestCase {
    func testSubstringRejectsOverflowingUTF16Range() {
        let text = "selected"
        let range = CFRange(location: Int.max, length: Int.max)

        let result = AccessibilitySelectedTextCapture.substring(in: text, utf16Range: range)

        XCTAssertNil(result)
    }

    func testSubstringUsesUTF16OffsetsSafely() {
        let text = "Hi 👋 world"
        let start = text.utf16.distance(from: text.utf16.startIndex, to: text.firstIndex(of: "w")!.samePosition(in: text.utf16)!)
        let range = CFRange(location: start, length: 5)

        let result = AccessibilitySelectedTextCapture.substring(in: text, utf16Range: range)

        XCTAssertEqual(result, "world")
    }
}
