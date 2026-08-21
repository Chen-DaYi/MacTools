import AppKit
import MacToolsPluginKit
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
    private var windowRouter: AppWindowRouter?
    private var statusItemController: MenuBarStatusItemController?
    private var actionGridOverlayController: ActionGridOverlayController?
    private lazy var automationStartupCoordinator = AutomationStartupCoordinator { [weak self] in
        self?.pluginHost.automationController.startAutomaticRules()
    }
    private lazy var runLinkFeedbackPresenter = SystemRunLinkFeedbackPresenter()
    private lazy var runLinkExecutionCoordinator = RunLinkExecutionCoordinator(
        registry: pluginHost.actionRegistry,
        executor: pluginHost.actionExecutor,
        runLinkService: pluginHost.actionRunLinkService,
        confirmationService: pluginHost.actionConfirmationService,
        feedbackPresenter: runLinkFeedbackPresenter
    )
    private lazy var appURLRouter = AppURLRouter(
        actionRejectionHandler: { [weak self] _, error in
            self?.runLinkExecutionCoordinator.presentRoutingRejection(error)
        }
    )

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
        pluginHost.installFocusedHostWindowProvider { [weak windowRouter] in
            windowRouter?.focusedWindowLayoutTarget
        }
        pluginHost.actionExecutionFeedbackHandler = { [weak self] source, reference, outcome in
            self?.presentHeadlessActionFeedback(
                source: source,
                reference: reference,
                outcome: outcome
            )
        }
        let actionConfirmationService = AppActionConfirmationService { [weak self] in
            self?.windowRouter?.windowForActionConfirmation()
        }
        pluginHost.actionConfirmationService.setHandler { request in
            await actionConfirmationService.confirm(request)
        }
        let actionGridOverlayController = ActionGridOverlayController(pluginHost: pluginHost)
        self.actionGridOverlayController = actionGridOverlayController
        pluginHost.installActionGridPresenter { [weak self, weak actionGridOverlayController] entries, source in
            self?.pluginHost.captureCurrentFocusedWindowTarget()
            return actionGridOverlayController?.present(entries: entries, source: source) ?? false
        }
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
        pluginHost.automationController.stopAutomaticRules()
        actionGridOverlayController?.close(restoringFocus: false)
        statusItemController?.dismissPanels()
        pluginHost.deactivateAllPlugins()
    }

    private func presentHeadlessActionFeedback(
        source: ActionExecutionSource,
        reference: ActionReference,
        outcome: ActionExecutionOutcome
    ) {
        guard reference.key.providerID == "window-layouts",
              source == .globalShortcut || source == .trackpadGesture,
              case let .success(action) = pluginHost.actionRegistry.registeredAction(for: reference)
        else {
            return
        }

        if let feedback = WindowLayoutActionFeedback.feedback(
            actionTitle: action.definition.title,
            outcome: outcome
        ) {
            runLinkFeedbackPresenter.present(feedback)
        }
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
                self?.pluginHost.hasPluginSettings(pluginID: pluginID) == true
            },
            actionIdentityResolver: { [weak self] request in
                self?.pluginHost.actionRunLinkService.resolve(request)
            },
            actionHandler: { [weak self] request, resolution in
                guard let self else { return .completed }
                if let resolution {
                    return await self.runLinkExecutionCoordinator.execute(resolution)
                }
                return await self.runLinkExecutionCoordinator.execute(request)
            }
        )
    }
}
