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
    private let instanceCoordinator: AppInstanceCoordinator
    private var launchDisposition: AppInstanceLaunchDisposition?
    private var didFinishLaunching = false
    private var runtime: MacToolsAppRuntime?
    private var instanceCoordinationTask: Task<Void, Never>?
    #if DEBUG
    private var showSettingsForTesting: (() -> Void)?
    #endif

    override init() {
        instanceCoordinator = AppInstanceCoordinator()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else {
            launchDisposition = .primary(recoveryRequested: false)
            return
        }

        launchDisposition = .secondary(.timedOut)
        let recoveryHandler = settingsRecoveryHandler()
        instanceCoordinationTask = Task { [weak self, instanceCoordinator, recoveryHandler] in
            await instanceCoordinator.setCommandHandler(recoveryHandler)
            let disposition: AppInstanceLaunchDisposition
            if await instanceCoordinator.claimPrimaryPortIfPossible() {
                disposition = .primary(recoveryRequested: false)
            } else {
                disposition = await instanceCoordinator.resolveSecondaryLaunch()
            }
            guard !Task.isCancelled else { return }
            self?.completeSecondaryLaunch(disposition)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        guard case let .primary(recoveryRequested) = launchDisposition else { return }
        startRuntime(recoveryRequested: recoveryRequested)
    }

    private func startRuntime(recoveryRequested: Bool) {
        guard runtime == nil else { return }
        let runtime = MacToolsAppRuntime()
        self.runtime = runtime
        runtime.start(notificationDelegate: self)
        if recoveryRequested {
            _ = requestSettingsRecovery()
        }
    }

    private func completeSecondaryLaunch(_ disposition: AppInstanceLaunchDisposition) {
        switch disposition {
        case let .primary(recoveryRequested):
            launchDisposition = disposition
            if didFinishLaunching {
                startRuntime(recoveryRequested: recoveryRequested)
            }
        case let .secondary(result):
            AppLog.instanceCoordination.notice("Secondary instance terminating: \(String(describing: result), privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        runtime?.handle(urls: urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        _ = requestSettingsRecovery()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceCoordinationTask?.cancel()
        instanceCoordinationTask = nil
        runtime?.terminate()
        Task { [instanceCoordinator] in
            await instanceCoordinator.invalidate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func requestSettingsRecovery() -> AppInstanceResponse {
        #if DEBUG
        if let showSettingsForTesting {
            showSettingsForTesting()
            return .accepted
        }
        #endif

        return runtime?.showSettings() == true ? .accepted : .notReady
    }

    private func settingsRecoveryHandler() -> @Sendable () -> AppInstanceResponse {
        { [weak self] in
            MainActor.assumeIsolated {
                self?.requestSettingsRecovery() ?? .notReady
            }
        }
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    func setShowSettingsForRecoveryForTesting(_ action: @escaping () -> Void) {
        showSettingsForTesting = action
    }

    func handleInstanceRecoveryCommandForTesting() -> AppInstanceResponse {
        settingsRecoveryHandler()()
    }
    #endif
}
