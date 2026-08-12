import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class MacToolsAppRuntime {
    private let pluginHost = PluginHost(
        loadDynamicPluginsOnInit: false,
        preferencesBackupStore: PreferencesBackupStore()
    )
    private let appUpdater = AppUpdater()
    private let menuBarIconSettings = MenuBarIconSettings()
    private let menuBarIconGallery = MenuBarIconGalleryLibrary()
    private let launchAtLoginController = LaunchAtLoginController()
    private let appearanceUserDefaults = UserDefaults.standard
    private let menuBarPanelThemeStore = MenuBarPanelThemeStore()
    private let pluginAutomaticUpdateVersionStore = PluginAutomaticUpdateVersionStore()
    private let appURLRouter = AppURLRouter()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?

    func start(notificationDelegate: UNUserNotificationCenterDelegate) {
        AppAppearancePreference.applyStoredPreference(userDefaults: appearanceUserDefaults)
        launchAtLoginController.refreshStatus()
        UNUserNotificationCenter.current().delegate = notificationDelegate

        let windowRouter = AppWindowRouter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarIconSettings: menuBarIconSettings,
            menuBarIconGallery: menuBarIconGallery,
            launchAtLoginController: launchAtLoginController,
            menuBarPanelThemeStore: menuBarPanelThemeStore,
            appearanceUserDefaults: appearanceUserDefaults
        )
        self.windowRouter = windowRouter
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            appUpdater: appUpdater,
            iconSettings: menuBarIconSettings,
            menuBarPanelThemeStore: menuBarPanelThemeStore
        )

        bootstrapDynamicPlugins()
    }

    func showSettings() -> Bool {
        guard let windowRouter else { return false }
        windowRouter.showSettings()
        return true
    }

    func handle(urls: [URL]) {
        appURLRouter.handle(urls)
    }

    func terminate() {
        statusItemController?.dismissPanels()
        pluginHost.deactivateAllPlugins()
    }

    private func bootstrapDynamicPlugins() {
        let currentAppVersion = AppMetadata.versionDescription

        guard pluginHost.hasInstalledDynamicPlugins else {
            pluginHost.loadDynamicPluginsIfNeeded()
            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
            activateAppURLRouter()
            return
        }

        let needsAutomaticUpdateCheck = pluginAutomaticUpdateVersionStore.needsAutomaticUpdateCheck(
            currentAppVersion: currentAppVersion
        )
        guard needsAutomaticUpdateCheck
            || pluginHost.hasPendingDynamicPluginExtractionMigration
        else {
            pluginHost.loadDynamicPluginsIfNeeded()
            activateAppURLRouter()
            return
        }

        Task { @MainActor in
            let updateSucceeded = await pluginHost.automaticUpdateInstalledPluginsBeforeLoading()
            if updateSucceeded {
                pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                    currentAppVersion: currentAppVersion
                )
            }
            activateAppURLRouter()
        }
    }

    private func activateAppURLRouter() {
        appURLRouter.activate(
            presentationHandler: { [weak self] request in
                self?.pluginHost.appPresentationHandler?(request)
            },
            isPluginConfigurationAvailable: { [weak self] pluginID in
                self?.pluginHost.hasPluginSettings(pluginID: pluginID) == true
            }
        )
    }
}
