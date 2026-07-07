import AppKit
import Foundation

enum ScreenshotCaptureError: Error, Equatable, Sendable {
    case screenRecordingPermissionRequired
    case cancelled
    case regionTooSmall
    case noScreen
    case screenshotFailed
}

struct ScreenshotCaptureResult: Equatable {
    var image: NSImage?
    var selectedRect: CGRect?
    var screenFrame: CGRect?
    var error: ScreenshotCaptureError?

    static func success(
        image: NSImage,
        selectedRect: CGRect,
        screenFrame: CGRect
    ) -> ScreenshotCaptureResult {
        ScreenshotCaptureResult(
            image: image,
            selectedRect: selectedRect,
            screenFrame: screenFrame,
            error: nil
        )
    }

    static func failure(_ error: ScreenshotCaptureError) -> ScreenshotCaptureResult {
        ScreenshotCaptureResult(
            image: nil,
            selectedRect: nil,
            screenFrame: nil,
            error: error
        )
    }
}

struct OCRRecognizedLine: Equatable, Sendable {
    var text: String
    var boundingBox: CGRect
    var confidence: Float
}

struct OCRTextRecognitionResult: Equatable, Sendable {
    var text: String
    var lines: [OCRRecognizedLine]

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
