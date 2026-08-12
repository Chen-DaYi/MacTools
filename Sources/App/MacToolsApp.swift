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
        .commands {
            // Settings is presented exclusively by AppWindowRouter. Remove the
            // placeholder scene's command so it can never expose an empty window.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

@MainActor
final class MacToolsAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
    private var showSettingsForReopen: (() -> Void)?
    #if DEBUG
    private var duplicateLaunchPollTimer: Timer?
    private var handledDuplicateProcessIdentifiers = Set<pid_t>()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearancePreference.applyStoredPreference(userDefaults: appearanceUserDefaults)
        launchAtLoginController.refreshStatus()
        UNUserNotificationCenter.current().delegate = self

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
        showSettingsForReopen = { [weak windowRouter] in
            windowRouter?.showSettings()
        }
        startDuplicateLaunchPollingIfNeeded()
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            appUpdater: appUpdater,
            iconSettings: menuBarIconSettings,
            menuBarPanelThemeStore: menuBarPanelThemeStore
        )

        bootstrapDynamicPlugins()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appURLRouter.handle(urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        showSettingsForReopen?()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        duplicateLaunchPollTimer?.invalidate()
        duplicateLaunchPollTimer = nil
        #endif
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

    #if DEBUG
    private func startDuplicateLaunchPollingIfNeeded() {
        guard duplicateLaunchPollTimer == nil else { return }
        duplicateLaunchPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showSettingsAfterDuplicateLaunchIfNeeded()
            }
        }
    }

    private func showSettingsAfterDuplicateLaunchIfNeeded() {
        let duplicateProcessIdentifiers = NSWorkspace.shared.runningApplications.compactMap { application in
            let processIdentifier = application.processIdentifier
            return AppDuplicateLaunchPolicy.shouldShowSettings(
                launchedBundleIdentifier: application.bundleIdentifier,
                launchedProcessIdentifier: processIdentifier,
                currentBundleIdentifier: Bundle.main.bundleIdentifier,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            ) ? processIdentifier : nil
        }
        let newDuplicateProcessIdentifiers = Set(duplicateProcessIdentifiers)
            .subtracting(handledDuplicateProcessIdentifiers)
        guard !newDuplicateProcessIdentifiers.isEmpty else { return }

        handledDuplicateProcessIdentifiers.formUnion(newDuplicateProcessIdentifiers)
        showSettingsForReopen?()
    }
    #endif

    #if DEBUG
    func setShowSettingsForReopenForTesting(_ action: @escaping () -> Void) {
        showSettingsForReopen = action
    }
    #endif
}

enum AppDuplicateLaunchPolicy {
    static func shouldShowSettings(
        launchedBundleIdentifier: String?,
        launchedProcessIdentifier: pid_t,
        currentBundleIdentifier: String?,
        currentProcessIdentifier: pid_t
    ) -> Bool {
        guard
            let launchedBundleIdentifier,
            let currentBundleIdentifier,
            launchedBundleIdentifier == currentBundleIdentifier
        else {
            return false
        }

        return launchedProcessIdentifier != currentProcessIdentifier
    }
}
