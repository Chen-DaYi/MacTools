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
        let toolbarItemIdentifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let sidebarToggleIndex = toolbarItemIdentifiers.firstIndex {
            $0.contains("toggleSidebar")
        }
        let splitSeparatorIndex = toolbarItemIdentifiers.firstIndex {
            $0.contains("splitViewSeparator")
        }

        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertNil(
            sidebarToggleIndex,
            "Expected the settings sidebar toggle to be removed, got \(toolbarItemIdentifiers)"
        )
        XCTAssertNotNil(
            splitSeparatorIndex,
            "Expected a split-view toolbar separator, got \(toolbarItemIdentifiers)"
        )
        if let splitSeparatorIndex {
            XCTAssertGreaterThanOrEqual(
                toolbarItemIdentifiers.count,
                splitSeparatorIndex + 3,
                "Expected separate history and title items after the sidebar separator"
            )
        }
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
            let currentToolbarItemIdentifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            XCTAssertEqual(window.frame.width, resizedWidth, accuracy: 0.5)
            XCTAssertFalse(
                currentToolbarItemIdentifiers.contains { $0.contains("toggleSidebar") },
                "Expected the settings sidebar toggle to remain removed, got \(currentToolbarItemIdentifiers)"
            )
            XCTAssertEqual(
                window.toolbar?.items.count,
                initialToolbarItemCount,
                "Expected a stable toolbar after navigating to \(destination), got \(currentToolbarItemIdentifiers)"
            )
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

    func testFeatureSettingsPresentationRoutesToRequestedPage() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.feature(.actionsAndShortcuts))
        XCTAssertEqual(
            router.settingsNavigationCoordinator?.destination,
            .plugins(.actionsAndShortcuts)
        )

        router.presentSettings(.feature(.automation))
        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .plugins(.automation))
        router.settingsWindow?.close()
    }

    func testWorkflowPresentationRoutesToTheExactAutomationEditor() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var createdWorkflow: WorkflowDefinition?
        let router = makeRouter(defaults: defaults) { host in
            createdWorkflow = host.automationController.createWorkflow()
        }
        let workflow = try XCTUnwrap(createdWorkflow)

        router.presentSettings(.automationWorkflow(workflow.id))

        XCTAssertEqual(
            router.settingsNavigationCoordinator?.destination,
            .plugins(.automation)
        )
        XCTAssertNil(
            router.settingsNavigationCoordinator?.searchRevealRequest,
            "The visible Automation editor should consume the exact workflow reveal request."
        )
        router.settingsWindow?.close()
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
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults
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
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults
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

    func testDockVisibilityPolicyUsesRegularActivationOnlyForVisibleSettings() {
        XCTAssertEqual(
            AppDockVisibilityPolicy.activationPolicy(hasVisibleSettingsWindow: true),
            .regular
        )
        XCTAssertEqual(
            AppDockVisibilityPolicy.activationPolicy(hasVisibleSettingsWindow: false),
            .accessory
        )
    }

    func testDockVisibilityControllerDoesNotMutateApplicationPolicyDuringTests() {
        var requestedPolicies = [NSApplication.ActivationPolicy]()
        let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool = { policy in
            requestedPolicies.append(policy)
            return true
        }

        AppDockVisibilityController.update(
            hasVisibleSettingsWindow: true,
            isRunningTests: true,
            setActivationPolicy: setActivationPolicy
        )
        XCTAssertTrue(requestedPolicies.isEmpty)

        AppDockVisibilityController.update(
            hasVisibleSettingsWindow: true,
            isRunningTests: false,
            setActivationPolicy: setActivationPolicy
        )
        XCTAssertEqual(requestedPolicies, [.regular])
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

    func testUnifiedPaletteViewportFitsCompleteNavigationRowsWhenSpaceAllows() {
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 710),
            UnifiedSearchPaletteLayout.maximumResultListHeight
        )
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 600),
            398
        )
        XCTAssertGreaterThanOrEqual(
            StandaloneCommandPaletteLayout.contentSize.height,
            UnifiedSearchPaletteLayout.maximumResultListHeight
                + UnifiedSearchPaletteLayout.verticalChromeHeight
        )
    }

    func testStandalonePaletteUsesStoredAppearanceOnItsPanelAndContent() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAppearancePreference.light.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        let router = makeRouter(defaults: defaults)

        router.toggleCommandPalette()
        let panel = try XCTUnwrap(router.commandPalettePanel)

        XCTAssertEqual(panel.appearance?.name, .aqua)
        XCTAssertEqual(panel.contentView?.appearance?.name, .aqua)
        router.dismissCommandPalette()
    }

    func testDismissingStandalonePaletteRestoresThePreviousApplication() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var restorationCount = 0
        let focusRestoration = StandaloneCommandPaletteFocusRestoration(
            captureRestoration: { { restorationCount += 1 } },
            canRestore: { true }
        )
        let router = makeRouter(
            defaults: defaults,
            commandPaletteFocusRestoration: focusRestoration
        )

        router.toggleCommandPalette()
        router.dismissCommandPalette()

        XCTAssertEqual(restorationCount, 1)
    }

    func testSuccessfulStandalonePaletteActionRestoresOnlyWhilePaletteOwnsFocus() {
        XCTAssertTrue(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: true,
                    applicationIsActive: true
                )
        )
        XCTAssertFalse(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: false,
                    applicationIsActive: true
                )
        )
        XCTAssertFalse(
            StandaloneCommandPaletteSuccessfulExecutionFocusPolicy
                .shouldRestorePreviousApplication(
                    paletteIsKey: true,
                    applicationIsActive: false
                )
        )
    }

    func testOpeningSettingsFromStandalonePaletteDoesNotRestoreThePreviousApplication() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var restorationCount = 0
        let focusRestoration = StandaloneCommandPaletteFocusRestoration(
            captureRestoration: { { restorationCount += 1 } },
            canRestore: { true }
        )
        let router = makeRouter(
            defaults: defaults,
            commandPaletteFocusRestoration: focusRestoration
        )

        router.toggleCommandPalette()
        router.presentSettings(.general)

        XCTAssertEqual(restorationCount, 0)
        router.settingsWindow?.close()
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

    func testStandalonePaletteDismissalExplicitlyCancelsOnlyPendingSurfaceWork() {
        let state = StandaloneCommandPaletteState()
        var cancellationCount = 0
        state.setPendingExecutionCancellation { cancellationCount += 1 }

        state.prepareForDismissal()
        state.prepareForDismissal()

        XCTAssertEqual(cancellationCount, 1)
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

    func testPhysicalCommandNumberSelectsSettingsPageWhenSearchIsClosed() throws {
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
        appUpdater: AppUpdater? = nil,
        commandPaletteFocusRestoration: StandaloneCommandPaletteFocusRestoration? = nil,
        configureHost: (PluginHost) -> Void = { _ in }
    ) -> AppWindowRouter {
        let host = PluginHost(
            plugins: [],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        configureHost(host)
        return AppWindowRouter(
            pluginHost: host,
            appUpdater: appUpdater ?? AppUpdater(startingUpdater: false),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: AppWindowRouterFakeLaunchAtLoginService()),
            appearanceUserDefaults: defaults,
            commandPaletteFocusRestoration: commandPaletteFocusRestoration ?? .init()
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
private final class AppWindowRouterFakeLaunchAtLoginService: LaunchAtLoginServicing {
    private var registered = false

    var isRegistered: Bool { registered }

    func register() throws {
        registered = true
    }

    func unregister() throws {
        registered = false
    }
}
