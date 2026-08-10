import AppKit
import Carbon
import XCTest
@testable import MacTools

@MainActor
final class AppWindowRouterTests: XCTestCase {
    func testDashboardTargetInvokesOnlyDashboardAction() {
        var dashboardCallCount = 0
        var featurePanelCallCount = 0
        let actions = SettingsPanelPresentationActions(
            showDashboard: { dashboardCallCount += 1 },
            showFeaturePanel: { featurePanelCallCount += 1 }
        )

        actions.present(.dashboard)

        XCTAssertEqual(dashboardCallCount, 1)
        XCTAssertEqual(featurePanelCallCount, 0)
    }

    func testFeaturePanelTargetInvokesOnlyFeaturePanelAction() {
        var dashboardCallCount = 0
        var featurePanelCallCount = 0
        let actions = SettingsPanelPresentationActions(
            showDashboard: { dashboardCallCount += 1 },
            showFeaturePanel: { featurePanelCallCount += 1 }
        )

        actions.present(.featurePanel)

        XCTAssertEqual(dashboardCallCount, 0)
        XCTAssertEqual(featurePanelCallCount, 1)
    }

    func testLocalCommandMatcherRecognizesSettingsAndSearchKeyEquivalents() {
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(keyCode: UInt16(kVK_ANSI_Semicolon), characters: ",")
            ),
            .showSettings
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "F",
                    modifiers: [.command, .capsLock]
                )
            ),
            .focusSearch
        )
        XCTAssertEqual(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_K),
                    characters: "K",
                    modifiers: [.command, .capsLock]
                )
            ),
            .showUnifiedSearch
        )
    }

    func testLocalCommandMatcherLeavesCloseQuitAndUnsupportedModifiersUntouched() {
        for keyCode in [kVK_ANSI_W, kVK_ANSI_Q] {
            XCTAssertNil(
                MacToolsLocalKeyboardCommand.resolve(
                    for: keyEvent(keyCode: UInt16(keyCode), characters: "")
                )
            )
        }

        XCTAssertNil(
            MacToolsLocalKeyboardCommand.resolve(
                for: keyEvent(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "f",
                    modifiers: [.command, .shift]
                )
            )
        )
    }

    func testWindowPresentationDeminiaturizesBeforeOrderingFront() {
        var events: [String] = []

        AppWindowPresentation.perform(
            isMiniaturized: true,
            activate: { events.append("activate") },
            deminiaturize: { events.append("deminiaturize") },
            orderFront: { events.append("orderFront") }
        )

        XCTAssertEqual(events, ["activate", "deminiaturize", "orderFront"])
    }

    func testSettingsPaletteVisibilityPolicyRejectsMiniaturizedAndInactiveSpaceWindows() {
        XCTAssertTrue(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: true,
                isWindowOnActiveSpace: true
            )
        )
        XCTAssertFalse(
            CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isWindowOnActiveSpace: false
            )
        )
    }

    func testStandalonePalettePlacementSelectsPointerScreenAndClampsToVisibleFrame() {
        let first = NSRect(x: 0, y: 0, width: 800, height: 600)
        let second = NSRect(x: 800, y: 100, width: 500, height: 400)

        let frame = StandaloneCommandPaletteLayout.frame(
            contentSize: NSSize(width: 720, height: 660),
            pointerLocation: NSPoint(x: 900, y: 200),
            visibleFrames: [first, second]
        )

        XCTAssertEqual(frame.size, second.size)
        XCTAssertTrue(second.contains(frame))
    }

    func testStandalonePaletteContentPreservesOuterPaddingOnCompactFrames() {
        let availableWidth: CGFloat = 500

        XCTAssertEqual(
            UnifiedSearchPaletteLayout.width(for: availableWidth)
                + UnifiedSearchPaletteLayout.outerHorizontalPadding,
            availableWidth
        )
    }

    func testStandalonePaletteUsesRightToLeftLayoutForArabicLocale() {
        XCTAssertEqual(
            StandaloneCommandPaletteRootView.layoutDirection(for: Locale(identifier: "ar")),
            .rightToLeft
        )
        XCTAssertEqual(
            StandaloneCommandPaletteRootView.layoutDirection(for: Locale(identifier: "en")),
            .leftToRight
        )
    }

    func testStandalonePaletteStateResetsAndRefocusesForEveryPresentation() {
        let state = StandaloneCommandPaletteState()
        state.prepareForPresentation(shortcutLabel: "⌥⌘P")
        let firstResetRequestID = state.resetRequestID
        let firstFocusRequestID = state.focusRequestID
        XCTAssertTrue(state.requestQuickSelection(number: 2))

        state.prepareForPresentation(shortcutLabel: "⌃⌥P")

        XCTAssertGreaterThan(state.resetRequestID, firstResetRequestID)
        XCTAssertGreaterThan(state.focusRequestID, firstFocusRequestID)
        XCTAssertNil(state.quickSelectionRequest)
        XCTAssertEqual(state.presentationOrigin, .globalShortcut("⌃⌥P"))
        XCTAssertEqual(state.shortcutHint, "⌃⌥P")
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
