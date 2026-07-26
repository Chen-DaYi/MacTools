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

    func testDefaultPanelPresentationActionsFailSafely() {
        let actions = SettingsPanelPresentationActions()

        actions.present(.dashboard)
        actions.present(.featurePanel)
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
    }

    func testLocalCommandMatcherLeavesNavigationCloseAndQuitCommandsUntouched() {
        for keyCode in [
            kVK_ANSI_1,
            kVK_ANSI_2,
            kVK_ANSI_3,
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

    func testAppUpdateRequestStillOpensAboutWhenAvailabilityExpires() throws {
        let suiteName = "AppWindowRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = makeRouter(defaults: defaults)

        router.presentSettings(.appUpdate)

        XCTAssertEqual(router.settingsNavigationCoordinator?.destination, .about)
        XCTAssertNil(router.settingsNavigationCoordinator?.aboutUpdateActionRequest)
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
