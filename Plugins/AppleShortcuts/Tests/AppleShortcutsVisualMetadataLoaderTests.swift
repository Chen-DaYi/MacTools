import AppKit
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

    func testDownscalesLargeIconsBelowTheEncodedByteBudget() throws {
        let largeIcon = try XCTUnwrap(Self.makePNGData(size: NSSize(width: 1_024, height: 1_024)))

        let downscaled = try XCTUnwrap(AppleShortcutsVisualMetadataLoader.downscaledIconData(
            largeIcon,
            maximumDimension: AppleShortcutsVisualMetadataLoader.maximumIconDimension
        ))
        let image = try XCTUnwrap(NSImage(data: downscaled))

        XCTAssertLessThanOrEqual(
            downscaled.count,
            AppleShortcutsVisualMetadataLoader.maximumEncodedIconByteCount
        )
        XCTAssertLessThanOrEqual(image.size.width, AppleShortcutsVisualMetadataLoader.maximumIconDimension)
        XCTAssertLessThanOrEqual(image.size.height, AppleShortcutsVisualMetadataLoader.maximumIconDimension)
    }

    func testDownscalingReturnsNilForUndecodableData() {
        XCTAssertNil(AppleShortcutsVisualMetadataLoader.downscaledIconData(
            Data([0x00, 0x01, 0x02]),
            maximumDimension: AppleShortcutsVisualMetadataLoader.maximumIconDimension
        ))
    }

    private static func makePNGData(size: NSSize) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
