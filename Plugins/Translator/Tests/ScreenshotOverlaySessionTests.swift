import XCTest
@testable import TranslatorPlugin

@MainActor
final class ScreenshotOverlaySessionTests: XCTestCase {
    func testCancellationDismissesPresentedOverlayWindow() async {
        let window = RecordingScreenshotOverlayWindow()
        let session = ScreenshotOverlaySession(
            hasAvailableScreens: { true },
            activateApplication: {},
            overlayWindowPresenter: { onComplete in
                return [window]
            }
        )

        let task = Task {
            await session.selectRegion()
        }
        await waitUntil { window.showCount == 1 }

        task.cancel()
        await waitUntil { window.dismissCount == 1 }

        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            await Task.yield()
        }

        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class RecordingScreenshotOverlayWindow: ScreenshotOverlayWindowManaging {
    private(set) var showCount = 0
    private(set) var keyCount = 0
    private(set) var dismissCount = 0

    func showOverlayWindow() {
        showCount += 1
    }

    func makeOverlayKeyWindow() {
        keyCount += 1
    }

    func dismissOverlayWindow() {
        dismissCount += 1
    }
}
