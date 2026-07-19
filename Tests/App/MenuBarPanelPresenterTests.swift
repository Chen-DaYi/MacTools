import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelPresenterTests: XCTestCase {
    private let suiteName = "MenuBarPanelPresenterTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPopoverBehaviorLetsStatusControllerOwnDismissal() {
        XCTAssertEqual(MenuBarPanelPresenter.popoverBehavior, .applicationDefined)
    }

    func testUnifiedPanelUsesComponentGridWidth() {
        XCTAssertEqual(MenuBarPanelLayout.baseWidth, ComponentPanelLayout.panelWidth)
    }

    func testPopoverSizingIsLayoutDriven() throws {
        if #available(macOS 14.0, *) {
            let presenter = makePresenter()
            let popover = presenter.debugPopoverForTests
            let controller = try XCTUnwrap(
                popover.contentViewController as? NSHostingController<MenuBarUnifiedPanelContent>
            )

            XCTAssertTrue(controller.sizingOptions.isEmpty)
        }
    }

    func testUnifiedPanelModelForwardsSelectionWithoutReplacingRoot() {
        let model = MenuBarUnifiedPanelModel(
            selectedTab: .components,
            contentHeight: 100,
            maximumFeatureListHeight: 300,
            isPanelVisible: true
        )
        var selectedTab: MenuBarPanelTab?
        model.onTabSelection = { selectedTab = $0 }

        model.selectTab(.features)
        XCTAssertEqual(selectedTab, .features)
        XCTAssertEqual(model.selectedTab, .components)
        XCTAssertEqual(model.contentHeight, 100)
    }

    func testPanelCommandNumberShortcutsUsePhysicalNumberRowAcrossLayouts() {
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(
                    characters: "&",
                    keyCode: UInt16(kVK_ANSI_1)
                )
            ),
            .components
        )
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(
                    characters: "é",
                    keyCode: UInt16(kVK_ANSI_2)
                )
            ),
            .features
        )
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(
                    characters: "1",
                    keyCode: UInt16(kVK_ANSI_1),
                    modifiers: [.command, .capsLock]
                )
            ),
            .components
        )
    }

    func testPanelShortcutResolverIgnoresOtherKeysAndModifiers() {
        XCTAssertNil(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(
                    characters: "1",
                    keyCode: UInt16(kVK_ANSI_3)
                )
            )
        )
        XCTAssertNil(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(
                    characters: "!",
                    keyCode: UInt16(kVK_ANSI_1),
                    modifiers: [.command, .shift]
                )
            )
        )
    }

    func testPanelModelSelectionUsesPresenterRoutingWithoutShowingWindow() throws {
        let presenter = makePresenter()
        let popover = presenter.debugPopoverForTests
        let controller = try XCTUnwrap(
            popover.contentViewController as? NSHostingController<MenuBarUnifiedPanelContent>
        )
        XCTAssertEqual(controller.rootView.model.selectedTab, .components)

        controller.rootView.model.selectTab(.features)

        XCTAssertEqual(controller.rootView.model.selectedTab, .features)
        XCTAssertFalse(controller.rootView.model.isPanelVisible)
    }

    func testPopoverLifecycleInstallsAndRemovesKeyboardShortcutMonitor() {
        let presenter = makePresenter()
        let popover = presenter.debugPopoverForTests
        let willShow = Notification(name: NSPopover.willShowNotification, object: popover)
        let didClose = Notification(name: NSPopover.didCloseNotification, object: popover)

        XCTAssertFalse(presenter.debugHasKeyboardShortcutMonitorForTests)

        presenter.popoverWillShow(willShow)
        presenter.popoverWillShow(willShow)
        XCTAssertTrue(presenter.debugHasKeyboardShortcutMonitorForTests)

        presenter.popoverDidClose(didClose)
        XCTAssertFalse(presenter.debugHasKeyboardShortcutMonitorForTests)
    }

    func testClearingAutomaticInitialFocusLeavesTheWindowAsFirstResponder() {
        let window = makeWindow()
        let textField = NSTextField()
        window.contentView?.addSubview(textField)
        XCTAssertTrue(window.makeFirstResponder(textField))

        MenuBarPanelPresenter.clearAutomaticInitialFocus(in: window)

        XCTAssertTrue(window.firstResponder === window)
    }

    func testContainsPresentedWindowIncludesMarkedSecondaryPanelWindow() {
        let presenter = makePresenter()
        let window = makeWindow()
        MenuBarPanelWindowRegistry.markSecondaryPanel(window)

        XCTAssertTrue(presenter.containsPresentedWindow(window))
    }

    func testContainsPresentedWindowRejectsUnmarkedWindow() {
        let presenter = makePresenter()
        let window = makeWindow()

        XCTAssertFalse(presenter.containsPresentedWindow(window))
    }

    func testExplicitPresentationOpensClosedSurface() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: false,
                selectedTab: .components,
                requestedTab: .features
            ),
            .open
        )
    }

    func testExplicitPresentationSwitchesOpenSurface() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: true,
                selectedTab: .components,
                requestedTab: .features
            ),
            .switchPanel
        )
    }

    func testExplicitPresentationFocusesAlreadyOpenSurfaceWithoutClosing() {
        XCTAssertEqual(
            MenuBarPanelPresentationAction.resolve(
                isPanelShown: true,
                selectedTab: .features,
                requestedTab: .features
            ),
            .focus
        )
    }

    private func makePresenter() -> MenuBarPanelPresenter {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        return MenuBarPanelPresenter(
            pluginHost: host,
            onDismiss: {},
            onOpenSettings: {},
            onPresentDiskCleanConfiguration: {},
            onPresentLaunchControlConfiguration: {},
            onAllPanelsClosed: {}
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }

    private func makeCommandKeyEvent(
        characters: String,
        keyCode: UInt16,
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
