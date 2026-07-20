import AppKit
import Carbon
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class SettingsDestinationShortcutButtonsTests: XCTestCase {
    func testCommandNumberShortcutsSelectMatchingDestinations() {
        var selection = SettingsDestination.general
        let window = makeWindow(selection: Binding(
            get: { selection },
            set: { selection = $0 }
        ))

        XCTAssertTrue(performCommandShortcut(key: "2", keyCode: UInt16(kVK_ANSI_2), in: window))
        XCTAssertEqual(selection, .pluginConfiguration)

        XCTAssertTrue(performCommandShortcut(key: "3", keyCode: UInt16(kVK_ANSI_3), in: window))
        XCTAssertEqual(selection, .about)

        XCTAssertTrue(performCommandShortcut(key: "1", keyCode: UInt16(kVK_ANSI_1), in: window))
        XCTAssertEqual(selection, .general)
    }

    func testCurrentAndUnknownDestinationsDoNotChangeSelection() {
        var selection = SettingsDestination.general
        var selectionCount = 0
        let window = makeWindow(selection: Binding(
            get: { selection },
            set: {
                selection = $0
                selectionCount += 1
            }
        ))

        XCTAssertTrue(performCommandShortcut(key: "1", keyCode: UInt16(kVK_ANSI_1), in: window))
        XCTAssertEqual(selectionCount, 0)

        XCTAssertFalse(performCommandShortcut(key: "4", keyCode: UInt16(kVK_ANSI_4), in: window))
        XCTAssertEqual(selection, .general)
        XCTAssertEqual(selectionCount, 0)
    }

    private func makeWindow(selection: Binding<SettingsDestination>) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: SettingsDestinationShortcutButtons(selection: selection)
        )
        window.layoutIfNeeded()
        return window
    }

    private func performCommandShortcut(
        key: String,
        keyCode: UInt16,
        in window: NSWindow
    ) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )!
        return window.performKeyEquivalent(with: event)
    }
}
