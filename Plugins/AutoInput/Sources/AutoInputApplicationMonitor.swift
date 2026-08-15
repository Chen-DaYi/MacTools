import AppKit
import Foundation

@MainActor
protocol AutoInputApplicationMonitoring: AnyObject {
    var onApplicationActivated: ((AutoInputApplication) -> Void)? { get set }
    var frontmostApplication: AutoInputApplication? { get }

    func start()
    func stop()
}

@MainActor
final class WorkspaceAutoInputApplicationMonitor: AutoInputApplicationMonitoring {
    var onApplicationActivated: ((AutoInputApplication) -> Void)?

    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
    }

    var frontmostApplication: AutoInputApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap(Self.snapshot)
    }

    func start() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let snapshot = Self.snapshot(application)
            else { return }

            // NSWorkspace can invoke a `.main` observer on the main thread without installing
            // Swift's MainActor executor metadata. Hop explicitly instead of using
            // MainActor.assumeIsolated, which traps on macOS 27 when an overlay activates MacTools.
            DispatchQueue.main.async { [weak self] in
                self?.onApplicationActivated?(snapshot)
            }
        }
    }

    func stop() {
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    private nonisolated static func snapshot(_ application: NSRunningApplication) -> AutoInputApplication? {
        guard let bundleIdentifier = application.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty
        else { return nil }

        return AutoInputApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            bundleURL: application.bundleURL
        )
    }
}
