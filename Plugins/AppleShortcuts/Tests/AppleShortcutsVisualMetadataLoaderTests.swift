import Foundation
import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsVisualMetadataLoaderTests: XCTestCase {
    func testDecodesAppleEventRGBColorComponents() throws {
        let color = try XCTUnwrap(AppleShortcutsVisualMetadataLoader.color(
            red: Int32(UInt16.max),
            green: Int32(UInt16.max / 2),
            blue: 0
        ))

        XCTAssertEqual(color.red, 1, accuracy: 0.000_1)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(color.blue, 0, accuracy: 0.000_1)
    }

    func testRejectsOutOfRangeColorComponents() {
        XCTAssertNil(AppleShortcutsVisualMetadataLoader.color(red: -1, green: 0, blue: 0))
        XCTAssertNil(AppleShortcutsVisualMetadataLoader.color(
            red: Int32(UInt16.max) + 1,
            green: 0,
            blue: 0
        ))
    }

    func testRetainsIconsOnlyWithinTheTotalMemoryBudget() {
        var remainingByteCount = 2
        let firstIcon = Data([0x01, 0x02])

        XCTAssertEqual(
            AppleShortcutsVisualMetadataLoader.retainedIconData(
                firstIcon,
                remainingByteCount: &remainingByteCount
            ),
            firstIcon
        )
        XCTAssertEqual(remainingByteCount, 0)
        XCTAssertNil(AppleShortcutsVisualMetadataLoader.retainedIconData(
            Data([0x03]),
            remainingByteCount: &remainingByteCount
        ))
    }
}
