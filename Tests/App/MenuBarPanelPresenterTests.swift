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

    func testPanelCommandResolverAddsSettingsWithoutCapturingSearchCloseOrQuit() {
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "\u{1B}",
                    keyCode: UInt16(kVK_Escape),
                    modifiers: []
                )
            ),
            .dismissPanel
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: ",",
                    keyCode: UInt16(kVK_ANSI_Comma)
                )
            ),
            .showSettings
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "k",
                    keyCode: UInt16(kVK_ANSI_K)
                )
            ),
            .showUnifiedSearch
        )
        XCTAssertEqual(
            MenuBarPanelKeyboardAction.resolve(
                for: makeCommandKeyEvent(
                    characters: "1",
                    keyCode: UInt16(kVK_ANSI_1)
                )
            ),
            .selectTab(.components)
        )

        for keyCode in [kVK_ANSI_F, kVK_ANSI_W, kVK_ANSI_Q] {
            XCTAssertNil(
                MenuBarPanelKeyboardAction.resolve(
                    for: makeCommandKeyEvent(
                        characters: "",
                        keyCode: UInt16(keyCode)
                    )
                )
            )
        }
    }

    func testPanelSettingsCommandUsesInjectedWindowRouterPath() {
        var presentationCount = 0
        let presenter = makePresenter(
            onOpenSettings: { presentationCount += 1 }
        )

        presenter.performKeyboardAction(.showSettings)

        XCTAssertEqual(presentationCount, 1)
    }

    func testPanelUnifiedSearchCommandUsesInjectedWindowRouterPath() {
        var presentationCount = 0
        let presenter = makePresenter(
            onOpenUnifiedSearch: { presentationCount += 1 }
        )

        presenter.performKeyboardAction(.showUnifiedSearch)

        XCTAssertEqual(presentationCount, 1)
    }

    func testEscapeUsesCoordinatedPanelDismissalPath() {
        var dismissalCount = 0
        let presenter = makePresenter(onDismiss: { dismissalCount += 1 })

        presenter.performKeyboardAction(.dismissPanel)

        XCTAssertEqual(dismissalCount, 1)
    }

    func testUnhandledEscapeFromFocusedChildUsesHostingControllerFallback() throws {
        var dismissalCount = 0
        let window = makeWindow()
        let controller = MenuBarPanelHostingController(
            rootView: EmptyView(),
            onUnhandledEscape: { dismissalCount += 1 }
        )
        window.contentViewController = controller
        let control = EscapeForwardingView(frame: .zero)
        controller.view.addSubview(control)
        XCTAssertTrue(window.makeFirstResponder(control))

        window.sendEvent(makeEscapeKeyEvent(windowNumber: window.windowNumber))

        XCTAssertEqual(dismissalCount, 1)
    }

    func testFocusedChildCanConsumeActualEscapeEventBeforePanelFallback() {
        var dismissalCount = 0
        let window = makeWindow()
        let controller = MenuBarPanelHostingController(
            rootView: EmptyView(),
            onUnhandledEscape: { dismissalCount += 1 }
        )
        window.contentViewController = controller
        let control = EscapeConsumingView(frame: .zero)
        controller.view.addSubview(control)
        XCTAssertTrue(window.makeFirstResponder(control))

        window.sendEvent(makeEscapeKeyEvent(windowNumber: window.windowNumber))

        XCTAssertEqual(control.escapeCount, 1)
        XCTAssertEqual(dismissalCount, 0)
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

    func testTogglePresentationOpensRequestedSurfaceWhenClosed() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: false,
                selectedTab: .features,
                requestedTab: .components
            ),
            .open
        )
    }

    func testTogglePresentationClosesAlreadyOpenRequestedSurface() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: true,
                selectedTab: .components,
                requestedTab: .components
            ),
            .close
        )
    }

    func testTogglePresentationSwitchesDirectlyFromOtherOpenSurface() {
        XCTAssertEqual(
            MenuBarPanelToggleAction.resolve(
                isPanelShown: true,
                selectedTab: .features,
                requestedTab: .components
            ),
            .switchPanel
        )
    }

    private func makePresenter(
        onDismiss: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOpenUnifiedSearch: @escaping () -> Void = {}
    ) -> MenuBarPanelPresenter {
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
            appUpdater: AppUpdater(startingUpdater: false),
            onDismiss: onDismiss,
            onOpenUpdate: {},
            onOpenSettings: onOpenSettings,
            onOpenUnifiedSearch: onOpenUnifiedSearch,
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

    private func makeEscapeKeyEvent(windowNumber: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        )!
    }
}

private final class EscapeForwardingView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        nextResponder?.keyDown(with: event)
    }
}

private final class EscapeConsumingView: NSView {
    private(set) var escapeCount = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Escape) else {
            super.keyDown(with: event)
            return
        }

        escapeCount += 1
    }
}
