import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MacToolsAppDelegateTests: XCTestCase {
    func testReopeningMacToolsShowsSettingsWithOrWithoutExistingWindows() {
        for hasVisibleWindows in [false, true] {
            let delegate = MacToolsAppDelegate()
            var showSettingsCount = 0
            delegate.setShowSettingsForRecoveryForTesting {
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
