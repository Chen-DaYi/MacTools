import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol ScreenshotRegionCapturing {
    func captureRegion() async -> ScreenshotCaptureResult
}

struct ScreenshotOverlaySelection: Equatable, Sendable {
    var displayID: CGDirectDisplayID?
    var screenFrame: CGRect
    var backingScaleFactor: CGFloat
    var selectedRect: CGRect

    init(
        displayID: CGDirectDisplayID?,
        screenFrame: CGRect,
        backingScaleFactor: CGFloat,
        selectedRect: CGRect
    ) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.backingScaleFactor = backingScaleFactor
        self.selectedRect = selectedRect
    }

    @MainActor
    init(screen: NSScreen, selectedRect: CGRect) {
        self.init(
            displayID: screen.displayID,
            screenFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            selectedRect: selectedRect
        )
    }
}

enum ScreenshotOverlaySelectionResult: Equatable, Sendable {
    case success(ScreenshotOverlaySelection)
    case failure(ScreenshotCaptureError)
}

@MainActor
protocol ScreenshotOverlaySelecting: AnyObject {
    func selectRegion() async -> ScreenshotOverlaySelectionResult
}

@MainActor
final class ScreenshotRegionCapturer: ScreenshotRegionCapturing {
    private let screenRecordingPermissionProvider: () -> Bool
    private let overlaySelector: any ScreenshotOverlaySelecting
    private let displayImageProvider: (CGDirectDisplayID) -> CGImage?

    init(
        screenRecordingPermissionProvider: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        },
        overlaySelector: (any ScreenshotOverlaySelecting)? = nil,
        displayImageProvider: @escaping (CGDirectDisplayID) -> CGImage? = CGDisplayCreateImage
    ) {
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.overlaySelector = overlaySelector ?? ScreenshotOverlaySession()
        self.displayImageProvider = displayImageProvider
    }

    func captureRegion() async -> ScreenshotCaptureResult {
        guard screenRecordingPermissionProvider() else {
            return .failure(.screenRecordingPermissionRequired)
        }

        switch await overlaySelector.selectRegion() {
        case let .success(selection):
            return capture(selection)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func capture(_ selection: ScreenshotOverlaySelection) -> ScreenshotCaptureResult {
        guard let screenID = selection.displayID else {
            return .failure(.noScreen)
        }
        guard let displayImage = displayImageProvider(screenID) else {
            return .failure(.screenshotFailed)
        }

        let scale = selection.backingScaleFactor
        let cropRect = CGRect(
            x: selection.selectedRect.minX * scale,
            y: selection.selectedRect.minY * scale,
            width: selection.selectedRect.width * scale,
            height: selection.selectedRect.height * scale
        ).integral

        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: displayImage.width, height: displayImage.height)
        )
        let boundedCropRect = cropRect.intersection(imageBounds)

        guard !boundedCropRect.isNull,
              !boundedCropRect.isEmpty,
              let croppedImage = displayImage.cropping(to: boundedCropRect) else {
            return .failure(.screenshotFailed)
        }

        let image = NSImage(cgImage: croppedImage, size: selection.selectedRect.size)
        return .success(
            image: image,
            selectedRect: selection.selectedRect,
            screenFrame: selection.screenFrame
        )
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
