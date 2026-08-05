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
    private let pluginAutomaticUpdateVersionStore = PluginAutomaticUpdateVersionStore()
    private let appURLRouter = AppURLRouter()
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?
    private var actionGridOverlayController: ActionGridOverlayController?
    private lazy var automationStartupCoordinator = AutomationStartupCoordinator { [weak self] in
        self?.pluginHost.automationController.startAutomaticRules()
    }
    private lazy var runLinkExecutionCoordinator = RunLinkExecutionCoordinator(
        registry: pluginHost.actionRegistry,
        executor: pluginHost.actionExecutor,
        runLinkService: pluginHost.actionRunLinkService,
        confirmationService: pluginHost.actionConfirmationService,
        feedbackPresenter: SystemRunLinkFeedbackPresenter()
    )

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
            appearanceUserDefaults: appearanceUserDefaults
        )
        self.windowRouter = windowRouter
        let actionConfirmationService = AppActionConfirmationService { [weak self] in
            self?.windowRouter?.windowForActionConfirmation()
        }
        pluginHost.actionConfirmationService.setHandler { request in
            await actionConfirmationService.confirm(request)
        }
        let actionGridOverlayController = ActionGridOverlayController(pluginHost: pluginHost)
        self.actionGridOverlayController = actionGridOverlayController
        pluginHost.installActionGridPresenter { [weak actionGridOverlayController] entries in
            actionGridOverlayController?.present(entries: entries) ?? false
        }
        statusItemController = MenuBarStatusItemController(
            pluginHost: pluginHost,
            windowRouter: windowRouter,
            appUpdater: appUpdater,
            iconSettings: menuBarIconSettings
        )

        bootstrapDynamicPlugins()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appURLRouter.handle(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pluginHost.automationController.stopAutomaticRules()
        actionGridOverlayController?.close(restoringFocus: false)
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
            completeBootstrap()
            return
        }

        let needsAutomaticUpdateCheck = pluginAutomaticUpdateVersionStore.needsAutomaticUpdateCheck(
            currentAppVersion: currentAppVersion
        )
        guard needsAutomaticUpdateCheck
            || pluginHost.hasPendingDynamicPluginExtractionMigration
        else {
            pluginHost.loadDynamicPluginsIfNeeded()
            completeBootstrap()
            return
        }

        Task { @MainActor in
            await automationStartupCoordinator.startAfterActionRegistryPreparation {
                let updateSucceeded = await pluginHost
                    .automaticUpdateInstalledPluginsBeforeLoading()
                if updateSucceeded {
                    pluginAutomaticUpdateVersionStore.markAutomaticUpdateChecked(
                        currentAppVersion: currentAppVersion
                    )
                }
            }
            activateAppURLRouter()
        }
    }

    private func completeBootstrap() {
        automationStartupCoordinator.actionRegistryDidBecomeReady()
        activateAppURLRouter()
    }

    private func activateAppURLRouter() {
        appURLRouter.activate(
            presentationHandler: { [weak self] request in
                self?.pluginHost.appPresentationHandler?(request)
            },
            isPluginConfigurationAvailable: { [weak self] pluginID in
                self?.pluginHost.hasPluginConfiguration(pluginID: pluginID) == true
            },
            actionHandler: { [weak self] request in
                await self?.runLinkExecutionCoordinator.execute(request)
            }
        )
    }
}

/// Keeps one-shot automation events from observing an incomplete action registry
/// while installed dynamic plugins are still loading or updating.
@MainActor
final class AutomationStartupCoordinator {
    private let startAutomaticRules: () -> Void
    private(set) var hasStarted = false
    private(set) var isPreparing = false

    init(startAutomaticRules: @escaping () -> Void) {
        self.startAutomaticRules = startAutomaticRules
    }

    func actionRegistryDidBecomeReady() {
        guard !hasStarted else { return }
        hasStarted = true
        startAutomaticRules()
    }

    func startAfterActionRegistryPreparation(
        _ prepare: @MainActor () async -> Void
    ) async {
        guard !hasStarted, !isPreparing else { return }
        isPreparing = true
        await prepare()
        isPreparing = false
        actionRegistryDidBecomeReady()
    }
}
