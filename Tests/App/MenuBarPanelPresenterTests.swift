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

    func testPanelCommandNumberShortcutsResolveMatchingTabs() {
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(for: makeCommandKeyEvent(key: "1")),
            .components
        )
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(for: makeCommandKeyEvent(key: "2")),
            .features
        )
        XCTAssertEqual(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(key: "1", modifiers: [.command, .capsLock])
            ),
            .components
        )
    }

    func testPanelShortcutResolverIgnoresOtherKeysAndModifiers() {
        XCTAssertNil(
            MenuBarPanelPresenter.keyboardShortcutTab(for: makeCommandKeyEvent(key: "3"))
        )
        XCTAssertNil(
            MenuBarPanelPresenter.keyboardShortcutTab(
                for: makeCommandKeyEvent(key: "1", modifiers: [.command, .shift])
            )
        )
    }

    func testShownPanelCommandNumberShortcutsSwitchPresenterTabs() throws {
        let presenter = makePresenter()
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 24),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let button = NSStatusBarButton(frame: anchorWindow.contentView!.bounds)
        anchorWindow.contentView = button
        anchorWindow.orderFront(nil)
        defer {
            presenter.dismissPanels()
            anchorWindow.close()
        }

        presenter.toggleFeaturePanel(relativeTo: button)

        let popover = presenter.debugPopoverForTests
        let controller = try XCTUnwrap(
            popover.contentViewController as? NSHostingController<MenuBarUnifiedPanelContent>
        )
        let window = try XCTUnwrap(controller.view.window)
        XCTAssertEqual(controller.rootView.model.selectedTab, .features)

        NSApplication.shared.sendEvent(makeCommandKeyEvent(key: "1", in: window))
        XCTAssertEqual(controller.rootView.model.selectedTab, .components)
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
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        in window: NSWindow? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode(for: key)
        )!
    }

    private func keyCode(for key: String) -> UInt16 {
        switch key {
        case "1":
            return UInt16(kVK_ANSI_1)
        case "2":
            return UInt16(kVK_ANSI_2)
        default:
            return UInt16(kVK_ANSI_3)
        }
    }
}
