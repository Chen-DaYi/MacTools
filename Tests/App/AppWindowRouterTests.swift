import AppKit
import Carbon
import SwiftUI
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

    func testSettingsWindowKeepsItsWidthAcrossDestinations() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<SettingsView>)
        await settleWindowLayout(window)
        let initialWidth = window.frame.width
        let initialToolbarItemCount = window.toolbar?.items.count

        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertFalse(
            window.toolbar?.items.contains { $0.itemIdentifier == .toggleSidebar } ?? false
        )
        XCTAssertEqual(hostingView.sizingOptions, [])
        XCTAssertEqual(
            hostingView.frame.width,
            SettingsWindowLayout.defaultContentSize.width,
            accuracy: 0.5
        )

        window.setContentSize(NSSize(width: 940, height: 640))
        await settleWindowLayout(window)
        let resizedWidth = window.frame.width
        XCTAssertLessThan(resizedWidth, initialWidth)

        for destination in [
            SettingsNavigationDestination.plugins(.marketplace),
            .about,
            .general
        ] {
            coordinator.navigate(to: destination)
            await settleWindowLayout(window)
            XCTAssertEqual(window.frame.width, resizedWidth, accuracy: 0.5)
            XCTAssertEqual(window.toolbar?.items.count, initialToolbarItemCount)
        }

        window.close()
    }

    func testSettingsWindowOpensWithoutAutomaticInitialFocus() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.pluginMarketplace)

        let window = try XCTUnwrap(router.settingsWindow)
        await settleWindowLayout(window)
        for _ in 0..<5 {
            guard window.firstResponder !== window else {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(
            window.firstResponder === window,
            "Expected the window to own initial focus, got \(String(describing: window.firstResponder))"
        )

        window.close()
    }

    private func settleWindowLayout(_ window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        window.layoutIfNeeded()
    }

    func testSettingsWindowConstrainsLiveResizeToMinimumContentSize() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()

        let window = try XCTUnwrap(router.settingsWindow)
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: SettingsWindowLayout.minimumContentSize
            )
        ).size

        XCTAssertEqual(
            router.windowWillResize(window, to: NSSize(width: 400, height: 300)),
            minimumFrameSize
        )

        let largerSize = NSSize(width: 1200, height: 800)
        XCTAssertEqual(router.windowWillResize(window, to: largerSize), largerSize)

        window.close()
    }

    func testClosingSettingsWindowDiscardsNavigationHistory() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let router = AppWindowRouter(
            pluginHost: host,
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: FakeLaunchAtLoginService())
        )

        router.presentSettings(.pluginMarketplace)
        let firstCoordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertEqual(firstCoordinator.destination, .plugins(.marketplace))
        firstCoordinator.navigate(to: .about)

        try XCTUnwrap(router.settingsWindow).close()
        XCTAssertNil(router.settingsNavigationCoordinator)

        router.showSettings()
        let reopenedCoordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertEqual(reopenedCoordinator.history, [.general])
        XCTAssertFalse(reopenedCoordinator.canGoBack)

        try XCTUnwrap(router.settingsWindow).close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testInitializationDoesNotReplaceExistingAppPresentationHandler() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        var receivedRequests: [AppPresentationRequest] = []
        host.appPresentationHandler = { request in
            receivedRequests.append(request)
        }

        let router = AppWindowRouter(
            pluginHost: host,
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: FakeLaunchAtLoginService())
        )

        host.presentPluginMarketplace()

        XCTAssertEqual(receivedRequests, [.settings(.pluginMarketplace)])
        XCTAssertNil(router.settingsWindow)
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
        for keyCode in [
            kVK_ANSI_W,
            kVK_ANSI_Q
        ] {
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

    func testCommandCommaReusesSettingsWindowAndRequestsCoordinatedPanelDismissal() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let existingWindow = try XCTUnwrap(router.settingsWindow)
        var dismissalRequestCount = 0
        router.setProgrammaticSettingsPresentationAction {
            dismissalRequestCount += 1
        }
        existingWindow.orderOut(nil)

        XCTAssertTrue(
            existingWindow.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_Comma),
                    characters: ",",
                    windowNumber: existingWindow.windowNumber
                )
            )
        )

        XCTAssertTrue(router.settingsWindow === existingWindow)
        XCTAssertTrue(existingWindow.isVisible)
        XCTAssertEqual(dismissalRequestCount, 1)

        existingWindow.close()
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

    func testCommandFRequestsSearchOnlyForSearchableSettingsDestination() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        let commandF = keyEvent(
            keyCode: UInt16(kVK_ANSI_F),
            characters: "f",
            windowNumber: window.windowNumber
        )

        XCTAssertTrue(window.performKeyEquivalent(with: commandF))
        XCTAssertNil(coordinator.searchFocusRequest)

        coordinator.navigate(to: .plugins(.marketplace))
        XCTAssertTrue(window.performKeyEquivalent(with: commandF))
        let firstRequest = try XCTUnwrap(coordinator.searchFocusRequest)

        coordinator.setSearchField(.pluginMarketplace, focused: true)
        XCTAssertTrue(window.performKeyEquivalent(with: commandF))
        XCTAssertEqual(coordinator.searchFocusRequest, firstRequest)

        coordinator.navigate(to: .about)
        coordinator.setSearchField(.pluginMarketplace, focused: false)
        XCTAssertTrue(window.performKeyEquivalent(with: commandF))
        XCTAssertEqual(coordinator.searchFocusRequest, firstRequest)

        window.close()
    }

    func testCommandKReusesSettingsWindowAndRefocusesUnifiedSearch() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        let commandK = keyEvent(
            keyCode: UInt16(kVK_ANSI_K),
            characters: "k",
            windowNumber: window.windowNumber
        )

        XCTAssertTrue(window.performKeyEquivalent(with: commandK))
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .keyboard)
        let firstFocusRequestID = coordinator.unifiedSearchFocusRequestID

        XCTAssertTrue(window.performKeyEquivalent(with: commandK))
        XCTAssertTrue(router.settingsWindow === window)
        XCTAssertGreaterThan(
            coordinator.unifiedSearchFocusRequestID,
            firstFocusRequestID
        )

        window.close()
    }

    func testStandalonePaletteTogglesAndReusesOwnedResources() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)
        var panelDismissalRequests = 0
        router.setProgrammaticSettingsPresentationAction {
            panelDismissalRequests += 1
        }

        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)
        let state = try XCTUnwrap(router.commandPaletteState)
        let firstResetRequestID = state.resetRequestID
        let firstFocusRequestID = state.focusRequestID

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertEqual(panelDismissalRequests, 1)

        router.toggleCommandPalette()
        XCTAssertFalse(panel.isVisible)

        router.toggleCommandPalette()
        XCTAssertTrue(router.commandPalettePanel === panel)
        XCTAssertTrue(router.commandPaletteState === state)
        XCTAssertGreaterThan(state.resetRequestID, firstResetRequestID)
        XCTAssertGreaterThan(state.focusRequestID, firstFocusRequestID)

        router.dismissCommandPalette()
    }

    func testGlobalPaletteToggleDismissesSettingsPaletteWithoutCreatingAnotherPanel() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showUnifiedSearch()
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)

        router.toggleCommandPalette()

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(router.commandPalettePanel)
        router.settingsWindow?.close()
    }

    func testGlobalPaletteToggleReplacesHiddenSettingsPaletteWithStandalonePanel() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showUnifiedSearch()
        let settingsWindow = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        settingsWindow.orderOut(nil)

        router.toggleCommandPalette()

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertTrue(router.commandPalettePanel?.isVisible == true)
        router.dismissCommandPalette()
        settingsWindow.close()
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

    func testStandaloneNavigationOpensSettingsAndPreservesExactRevealTarget() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)
        let target = SettingsSearchRevealTarget.general(.appShortcuts)

        XCTAssertTrue(
            router.navigateFromStandaloneSearch(
                to: .general,
                target: target
            )
        )

        XCTAssertTrue(router.settingsWindow?.isVisible == true)
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .general)
        XCTAssertEqual(router.settingsNavigationCoordinator?.searchRevealRequest?.target, target)
        router.settingsWindow?.close()
    }

    func testUnavailableStandaloneNavigationKeepsPaletteVisibleAndSettingsClosed() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)
        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)

        XCTAssertFalse(
            router.navigateFromStandaloneSearch(
                to: .plugins(.configuration("missing-plugin")),
                target: nil
            )
        )

        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(router.settingsWindow)
        router.dismissCommandPalette()
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

    func testAppDeactivationDismissesStandalonePalette() async throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)
        XCTAssertTrue(panel.isVisible)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApplication.shared
        )
        await Task.yield()

        XCTAssertFalse(panel.isVisible)
    }

    func testPhysicalCommandNumberSelectsSettingsTabWhenSearchIsClosed() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showSettings()
        let window = try XCTUnwrap(router.settingsWindow)
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)

        XCTAssertTrue(
            window.performKeyEquivalent(
                with: keyEvent(
                    keyCode: UInt16(kVK_ANSI_3),
                    characters: "\"",
                    windowNumber: window.windowNumber
                )
            )
        )
        XCTAssertEqual(coordinator.destination, .about)

        window.close()
    }

    func testAppUpdateRequestNavigatesDirectlyToAbout() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = AppUpdater(startingUpdater: false)
        updater.setAvailableUpdateVersionForTests("1.2.3")
        let router = makeRouter(defaults: defaults, appUpdater: updater)

        router.presentSettings(.appUpdate)

        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .about)
        router.settingsWindow?.close()
    }

    func testExplicitGeneralAndAboutRequestsSelectTheirSettingsDestinations() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.about)
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .about)

        router.presentSettings(.general)
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .general)

        router.settingsWindow?.close()
    }

    func testExplicitSettingsRequestsDismissUnifiedSearchInArrivalOrder() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.showUnifiedSearch()
        let coordinator = try XCTUnwrap(router.settingsNavigationCoordinator)
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)

        router.presentSettings(.general)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)

        router.showUnifiedSearch()
        router.presentSettings(.settings)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)

        router.settingsWindow?.close()
    }

    private func makeRouter(
        defaults: UserDefaults,
        appUpdater: AppUpdater? = nil
    ) -> AppWindowRouter {
        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        return AppWindowRouter(
            pluginHost: host,
            appUpdater: appUpdater ?? AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: FakeLaunchAtLoginService())
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}
