import AppKit
import Carbon
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class SettingsDestinationShortcutButtonsTests: XCTestCase {
    func testCommandNumberShortcutsSelectMatchingDestinations() {
        let coordinator = SettingsNavigationCoordinator(
            pluginSettingsLandingPage: { .featurePanelLayout }
        )
        let window = makeWindow(coordinator: coordinator)

        XCTAssertTrue(performCommandShortcut(key: "2", keyCode: UInt16(kVK_ANSI_2), in: window))
        XCTAssertEqual(coordinator.destination, .plugins(.featurePanelLayout))

        XCTAssertTrue(performCommandShortcut(key: "3", keyCode: UInt16(kVK_ANSI_3), in: window))
        XCTAssertEqual(coordinator.destination, .about)

        XCTAssertTrue(performCommandShortcut(key: "1", keyCode: UInt16(kVK_ANSI_1), in: window))
        XCTAssertEqual(coordinator.destination, .general)
    }

    func testCurrentAndUnknownDestinationsDoNotChangeSelection() {
        let coordinator = SettingsNavigationCoordinator()
        let window = makeWindow(coordinator: coordinator)

        XCTAssertTrue(performCommandShortcut(key: "1", keyCode: UInt16(kVK_ANSI_1), in: window))
        XCTAssertEqual(coordinator.history, [.general])

        XCTAssertFalse(performCommandShortcut(key: "4", keyCode: UInt16(kVK_ANSI_4), in: window))
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
    }

    func testCommandTwoPreservesCurrentPluginSubpage() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )
        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        let window = makeWindow(coordinator: coordinator)

        XCTAssertTrue(performCommandShortcut(key: "2", keyCode: UInt16(kVK_ANSI_2), in: window))
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
        XCTAssertEqual(coordinator.history, [.general, .plugins(.configuration("fan-control"))])
    }

    func testCommandBracketShortcutsTraverseSettingsHistory() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.navigate(to: .about)
        let window = makeWindow(coordinator: coordinator)

        XCTAssertTrue(performCommandShortcut(key: "[", keyCode: UInt16(kVK_ANSI_LeftBracket), in: window))
        XCTAssertEqual(coordinator.destination, .general)

        XCTAssertTrue(performCommandShortcut(key: "]", keyCode: UInt16(kVK_ANSI_RightBracket), in: window))
        XCTAssertEqual(coordinator.destination, .about)
    }

    private func makeWindow(coordinator: SettingsNavigationCoordinator) -> NSWindow {
        let window = MacToolsCommandWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.onLocalKeyboardCommand = { _ in }
        window.contentView = NSHostingView(
            rootView: SettingsDestinationShortcutButtons(coordinator: coordinator)
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
