import ApplicationServices
import Foundation
import OSLog

// MARK: - Protocols

/// Event source for Accessibility permission changes. Calls `onPermissionChange` when state changes.
/// Mirrors `DisplayConfigurationObserving` so permission state can be shared across plugins.
@MainActor
protocol AccessibilityPermissionObserving: AnyObject {
    var onPermissionChange: (() -> Void)? { get set }
}

// MARK: - Concrete Observer

/// Polls `AXIsProcessTrusted()` every second and notifies the host when state changes.
/// One app-wide timer avoids each plugin polling independently.
@MainActor
final class AccessibilityPermissionObserver: AccessibilityPermissionObserving {
    var onPermissionChange: (() -> Void)?

    private var lastKnownTrust: Bool
    private var pollingTimer: Timer?
    private let logger = AppLog.accessibilityPermissionObserver

    init() {
        lastKnownTrust = AXIsProcessTrusted()
        startPolling()
    }

    deinit {
        MainActor.assumeIsolated {
            pollingTimer?.invalidate()
        }
    }

    // MARK: - Private

    private func startPolling() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func poll() {
        let current = AXIsProcessTrusted()
        guard current != lastKnownTrust else { return }
        lastKnownTrust = current
        logger.info("Accessibility permission changed: \(current ? "trusted" : "revoked", privacy: .public)")
        onPermissionChange?()
    }
}
