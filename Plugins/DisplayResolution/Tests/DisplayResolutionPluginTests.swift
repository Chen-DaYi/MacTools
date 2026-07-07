import CoreGraphics
import XCTest
@testable import DisplayResolutionPlugin

final class DisplayResolutionPluginTests: XCTestCase {
    func testParseDisplayIDAcceptsOnlyExpectedPrefix() {
        XCTAssertEqual(DisplayResolutionPlugin.parseDisplayID(from: "display.1"), 1)
        XCTAssertNil(DisplayResolutionPlugin.parseDisplayID(from: "display.abc"))
        XCTAssertNil(DisplayResolutionPlugin.parseDisplayID(from: "foo.1"))
    }

    func testOptionTitleMarksNativeDefaultAndDPI() {
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 1, width: 3008, height: 1692, isNative: true)),
            "3008×1692 (原生)"
        )
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(for: makeMode(modeId: 2, width: 3008, height: 1692, isDefault: true)),
            "3008×1692 (默认)"
        )
        XCTAssertEqual(
            DisplayResolutionPlugin.optionTitle(
                for: makeMode(
                    modeId: 3,
                    width: 4096,
                    height: 2304,
                    pixelWidth: 4096,
                    pixelHeight: 2304,
                    isHiDPI: false
                )
            ),
            "4096×2304 (LoDPI)"
        )
    }

    func testVisibleModesKeepNativeAndCurrentModes() {
        let modes = [
            makeMode(modeId: 20, width: 1728, height: 1117, isNative: true),
            makeMode(modeId: 21, width: 1440, height: 900, isCurrent: true)
        ]

        XCTAssertEqual(Set(DisplayResolutionPlugin.visibleModes(modes).map(\.modeId)), Set([20, 21]))
    }

    func testDedupeModesPrefersCurrentThenHiDPIOrHigherRefresh() {
        XCTAssertEqual(
            DisplayResolutionController.deduplicateModes([
                makeMode(modeId: 40, width: 1512, height: 982, refreshRate: 60, isCurrent: true),
                makeMode(modeId: 41, width: 1512, height: 982, refreshRate: 120)
            ]).map(\.modeId),
            [40]
        )
        XCTAssertEqual(
            DisplayResolutionController.deduplicateModes([
                makeMode(modeId: 60, width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, isHiDPI: false),
                makeMode(modeId: 61, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, isHiDPI: true)
            ]).map(\.modeId),
            [61]
        )
    }

    func testSortModesOrdersByLogicalResolutionDescending() {
        let modes = [
            makeMode(modeId: 80, width: 3200, height: 1800, pixelWidth: 6400, pixelHeight: 3600),
            makeMode(modeId: 81, width: 5120, height: 2880, pixelWidth: 5120, pixelHeight: 2880, isHiDPI: false, isNative: true),
            makeMode(modeId: 82, width: 4096, height: 2304, pixelWidth: 4096, pixelHeight: 2304, isHiDPI: false),
            makeMode(modeId: 83, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, isNative: true)
        ]

        XCTAssertEqual(DisplayResolutionController.sortModes(modes).map(\.modeId), [81, 82, 80, 83])
    }

    private func makeMode(
        modeId: Int32,
        width: Int,
        height: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        refreshRate: Double = 60,
        isHiDPI: Bool = true,
        isNative: Bool = false,
        isDefault: Bool = false,
        isCurrent: Bool = false
    ) -> DisplayResolutionInfo {
        DisplayResolutionInfo(
            modeId: modeId,
            width: width,
            height: height,
            pixelWidth: pixelWidth ?? width * 2,
            pixelHeight: pixelHeight ?? height * 2,
            refreshRate: refreshRate,
            isHiDPI: isHiDPI,
            isNative: isNative,
            isDefault: isDefault,
            isCurrent: isCurrent
        )
    }
}
