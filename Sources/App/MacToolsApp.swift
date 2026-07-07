import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(MacToolsAppDelegate.self) private var appDelegate

    init() {
        AppLanguagePreference.applyStoredPreference()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let pluginHost = PluginHost(loadDynamicPluginsOnInit: false)
    private let appUpdater = AppUpdater()
    private let menuBarIconSettings = MenuBarIconSettings()
    private let menuBarIconGallery = MenuBarIconGalleryLibrary()
    private let launchAtLoginController = LaunchAtLoginController()
    private let pluginAutomaticUpdateVersionStore = PluginAutomaticUpdateVersionStore()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearancePreference.applyStoredPreference()
        launchAtLoginController.refreshStatus()
        UNUserNotificationCenter.current().delegate = self

        let windowRouter = AppWindowRouter(
            pluginHost: pluginHost,
            appUpdater: appUpdater,
            menuBarIconSettings: menuBarIconSettings,
            menuBarIconGallery: menuBarIconGallery,
            launchAtLoginController: launchAtLoginController
        )
        self.windowRouter = windowRouter
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            iconSettings: menuBarIconSettings
        )

        bootstrapDynamicPlugins()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        RightClickURLRouter.shared.handle(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.dismissPanels()
        pluginHost.deactivateAllPlugins()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func bootstrapDynamicPlugins() {
        let currentAppVersion = AppMetadata.versionDescription

        guard pluginHost.hasInstalledDynamicPlugins else {
            pluginHost.loadDynamicPluginsIfNeeded()
            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
            return
        }

        guard pluginAutomaticUpdateVersionStore.needsAutomaticUpdateCheck(
            currentAppVersion: currentAppVersion
        ) else {
            pluginHost.loadDynamicPluginsIfNeeded()
            return
        }

        Task { @MainActor in
            await pluginHost.automaticUpdateInstalledPluginsBeforeLoading()

            pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                currentAppVersion: currentAppVersion
            )
        }
    }
}
