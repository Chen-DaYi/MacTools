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

    private var observer: NSObjectProtocol?

    var frontmostApplication: AutoInputApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap(Self.snapshot)
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let snapshot = Self.snapshot(application)
            else { return }

            MainActor.assumeIsolated {
                self?.onApplicationActivated?(snapshot)
            }
        }
    }

    func stop() {
        guard let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
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
