import AppKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class ScreenshotRegionCapturerTests: XCTestCase {
    func testPermissionDeniedSkipsOverlayAndReturnsPermissionError() async {
        let overlay = RecordingScreenshotOverlaySelector(result: .failure(.cancelled))
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { false },
            overlaySelector: overlay
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .screenRecordingPermissionRequired)
        XCTAssertEqual(overlay.startCount, 0)
    }

    func testOverlayCancellationReturnsCancelledError() async {
        let overlay = RecordingScreenshotOverlaySelector(result: .failure(.cancelled))
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay
        )

        let result = await capturer.captureRegion()

        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(overlay.startCount, 1)
    }

    func testCaptureClampsIntegralCropRectToDisplayImageBounds() async throws {
        let displayImage = try XCTUnwrap(makeDisplayImage(width: 10, height: 10))
        let overlay = RecordingScreenshotOverlaySelector(
            result: .success(
                ScreenshotOverlaySelection(
                    displayID: 1,
                    screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    backingScaleFactor: 1,
                    selectedRect: CGRect(x: 0, y: 0, width: 10.1, height: 10.1)
                )
            )
        )
        let capturer = ScreenshotRegionCapturer(
            screenRecordingPermissionProvider: { true },
            overlaySelector: overlay,
            displayImageProvider: { _ in displayImage }
        )

        let result = await capturer.captureRegion()

        XCTAssertNil(result.error)
        XCTAssertNotNil(result.image)
    }

    private func makeDisplayImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

@MainActor
private final class RecordingScreenshotOverlaySelector: ScreenshotOverlaySelecting {
    var result: ScreenshotOverlaySelectionResult
    private(set) var startCount = 0

    init(result: ScreenshotOverlaySelectionResult) {
        self.result = result
    }

    func selectRegion() async -> ScreenshotOverlaySelectionResult {
        startCount += 1
        return result
    }
}
