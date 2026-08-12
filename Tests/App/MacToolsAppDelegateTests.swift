import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MacToolsAppDelegateTests: XCTestCase {
    func testLaunchingAnotherCopyOfMacToolsShowsSettingsInExistingInstance() {
        XCTAssertTrue(
            AppDuplicateLaunchPolicy.shouldShowSettings(
                launchedBundleIdentifier: "com.example.mactools",
                launchedProcessIdentifier: 200,
                currentBundleIdentifier: "com.example.mactools",
                currentProcessIdentifier: 100
            )
        )
    }

    func testLaunchingTheSameProcessOrAnotherAppDoesNotShowSettings() {
        XCTAssertFalse(
            AppDuplicateLaunchPolicy.shouldShowSettings(
                launchedBundleIdentifier: "com.example.mactools",
                launchedProcessIdentifier: 100,
                currentBundleIdentifier: "com.example.mactools",
                currentProcessIdentifier: 100
            )
        )
        XCTAssertFalse(
            AppDuplicateLaunchPolicy.shouldShowSettings(
                launchedBundleIdentifier: "com.example.other",
                launchedProcessIdentifier: 200,
                currentBundleIdentifier: "com.example.mactools",
                currentProcessIdentifier: 100
            )
        )
        XCTAssertFalse(
            AppDuplicateLaunchPolicy.shouldShowSettings(
                launchedBundleIdentifier: nil,
                launchedProcessIdentifier: 200,
                currentBundleIdentifier: nil,
                currentProcessIdentifier: 100
            )
        )
    }

    func testReopeningMacToolsShowsSettingsWithOrWithoutExistingWindows() {
        for hasVisibleWindows in [false, true] {
            let delegate = MacToolsAppDelegate()
            var showSettingsCount = 0
            delegate.setShowSettingsForReopenForTesting {
                showSettingsCount += 1
            }

            XCTAssertFalse(
                delegate.applicationShouldHandleReopen(
                    NSApplication.shared,
                    hasVisibleWindows: hasVisibleWindows
                )
            )
            XCTAssertEqual(showSettingsCount, 1)
        }
    }
}
