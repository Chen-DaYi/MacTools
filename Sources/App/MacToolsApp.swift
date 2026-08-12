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
    private var runtime: MacToolsAppRuntime?
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

        instanceCoordinator.setCommandHandler { [weak self] in
            self?.requestSettingsRecovery() ?? .notReady
        }

        let disposition = instanceCoordinator.acquireOrForwardSettingsRequest()
        launchDisposition = disposition

        guard case .primary = disposition else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard case let .primary(recoveryRequested) = launchDisposition else { return }

        let runtime = MacToolsAppRuntime()
        self.runtime = runtime
        runtime.start(notificationDelegate: self)
        if recoveryRequested {
            _ = requestSettingsRecovery()
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
        runtime?.terminate()
        instanceCoordinator.invalidate()
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

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    func setShowSettingsForRecoveryForTesting(_ action: @escaping () -> Void) {
        showSettingsForTesting = action
    }
    #endif
}
