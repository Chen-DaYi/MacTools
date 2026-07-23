import AppKit
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
            appUpdater: AppUpdater(),
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
            appUpdater: AppUpdater(),
            menuBarIconSettings: MenuBarIconSettings(userDefaults: defaults),
            menuBarIconGallery: MenuBarIconGalleryLibrary(),
            launchAtLoginController: LaunchAtLoginController(service: FakeLaunchAtLoginService())
        )

        host.presentPluginMarketplace()

        XCTAssertEqual(receivedRequests, [.settings(.pluginMarketplace)])
        XCTAssertNil(router.settingsWindow)
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
