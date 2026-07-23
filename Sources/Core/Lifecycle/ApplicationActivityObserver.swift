import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
protocol ApplicationActivityObserving: AnyObject {
    var state: PluginApplicationActivityState { get }
    var onStateChange: ((PluginApplicationActivityState) -> Void)? { get set }
}

struct ApplicationActivitySignals: Equatable {
    let isUserSessionActive: Bool
    let isScreenLocked: Bool
    let areDisplaysAsleep: Bool

    static let interactive = ApplicationActivitySignals(
        isUserSessionActive: true,
        isScreenLocked: false,
        areDisplaysAsleep: false
    )

    static func current() -> ApplicationActivitySignals {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isOnConsole = session?[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let isLoginDone = session?[kCGSessionLoginDoneKey as String] as? Bool ?? true
        // WindowServer includes lock state in the session dictionary even though
        // CoreGraphics does not publish a typed constant for this key.
        let isScreenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false

        return ApplicationActivitySignals(
            isUserSessionActive: isOnConsole && isLoginDone,
            isScreenLocked: isScreenLocked,
            areDisplaysAsleep: allOnlineDisplaysAreAsleep()
        )
    }

    private static func allOnlineDisplaysAreAsleep() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return CGDisplayIsAsleep(CGMainDisplayID()) != 0
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return CGDisplayIsAsleep(CGMainDisplayID()) != 0
        }

        return displays.prefix(Int(displayCount)).allSatisfy {
            CGDisplayIsAsleep($0) != 0
        }
    }
}

enum ApplicationActivityNotificationName {
    // loginwindow publishes these distributed notifications without public
    // Foundation constants. Keep their raw names next to the private CGS key.
    static let screenDidLock = Notification.Name("com.apple.screenIsLocked")
    static let screenDidUnlock = Notification.Name("com.apple.screenIsUnlocked")
}

/// Derives one activity state from the independent workspace session, display,
/// and system sleep notifications. Notification ordering is intentionally not
/// assumed.
@MainActor
final class SystemApplicationActivityObserver: ApplicationActivityObserving {
    private struct Observation {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private(set) var state: PluginApplicationActivityState = .interactive
    var onStateChange: ((PluginApplicationActivityState) -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let screenLockNotificationCenter: NotificationCenter
    private let wakeSettleDelay: Duration
    private let currentSignalsProvider: @MainActor () -> ApplicationActivitySignals
    private var observations: [Observation] = []
    private var wakeSettleTask: Task<Void, Never>?
    private var isUserSessionActive = true
    private var isScreenLocked = false
    private var areDisplaysAsleep = false
    private var isSystemSleeping = false
    private var isSettlingAfterWake = false

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenLockNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        wakeSettleDelay: Duration = .seconds(2),
        initialSignals: ApplicationActivitySignals? = nil,
        currentSignalsProvider: @escaping @MainActor () -> ApplicationActivitySignals = {
            ApplicationActivitySignals.current()
        }
    ) {
        self.workspaceNotificationCenter = notificationCenter
        self.screenLockNotificationCenter = screenLockNotificationCenter
        self.wakeSettleDelay = wakeSettleDelay
        self.currentSignalsProvider = currentSignalsProvider

        let resolvedInitialSignals = initialSignals ?? currentSignalsProvider()
        self.isUserSessionActive = resolvedInitialSignals.isUserSessionActive
        self.isScreenLocked = resolvedInitialSignals.isScreenLocked
        self.areDisplaysAsleep = resolvedInitialSignals.areDisplaysAsleep
        if resolvedInitialSignals.areDisplaysAsleep {
            state = .displayAsleep
        } else if !resolvedInitialSignals.isUserSessionActive
                    || resolvedInitialSignals.isScreenLocked {
            state = .sessionInactive
        }
        registerObservers()
    }

    isolated deinit {
        wakeSettleTask?.cancel()
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
    }

    private func registerObservers() {
        observe(NSWorkspace.sessionDidResignActiveNotification) { observer in
            observer.isUserSessionActive = false
            observer.publishResolvedState()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { observer in
            observer.isUserSessionActive = true
            observer.publishResolvedState()
        }
        observe(
            ApplicationActivityNotificationName.screenDidLock,
            on: screenLockNotificationCenter
        ) { observer in
            observer.refreshCurrentSignals()
            observer.isScreenLocked = true
            observer.publishResolvedState()
        }
        observe(
            ApplicationActivityNotificationName.screenDidUnlock,
            on: screenLockNotificationCenter
        ) { observer in
            observer.refreshCurrentSignals()
            observer.isScreenLocked = false
            observer.publishResolvedState()
        }
        observe(NSWorkspace.screensDidSleepNotification) { observer in
            observer.areDisplaysAsleep = true
            observer.publishResolvedState()
        }
        observe(NSWorkspace.screensDidWakeNotification) { observer in
            observer.refreshCurrentSignals()
            observer.areDisplaysAsleep = false
            observer.publishResolvedState()
        }
        observe(NSWorkspace.willSleepNotification) { observer in
            observer.wakeSettleTask?.cancel()
            observer.wakeSettleTask = nil
            observer.isSettlingAfterWake = false
            observer.isSystemSleeping = true
            observer.publishResolvedState()
        }
        observe(NSWorkspace.didWakeNotification) { observer in
            observer.isSystemSleeping = false
            observer.isSettlingAfterWake = true
            observer.publishResolvedState()
            observer.scheduleWakeSettlement()
        }
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter? = nil,
        handler: @escaping @MainActor (SystemApplicationActivityObserver) -> Void
    ) {
        let center = center ?? workspaceNotificationCenter
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observations.append(Observation(center: center, token: token))
    }

    private func scheduleWakeSettlement() {
        wakeSettleTask?.cancel()
        wakeSettleTask = Task { @MainActor [weak self, wakeSettleDelay] in
            do {
                try await Task.sleep(for: wakeSettleDelay, tolerance: .milliseconds(250))
            } catch {
                return
            }

            guard let self else { return }
            self.refreshCurrentSignals()
            self.isSettlingAfterWake = false
            self.wakeSettleTask = nil
            self.publishResolvedState()
        }
    }

    private func refreshCurrentSignals() {
        let signals = currentSignalsProvider()
        isUserSessionActive = signals.isUserSessionActive
        isScreenLocked = signals.isScreenLocked
        areDisplaysAsleep = signals.areDisplaysAsleep
    }

    private func publishResolvedState() {
        let newState: PluginApplicationActivityState
        if isSystemSleeping {
            newState = .systemSleeping
        } else if isSettlingAfterWake {
            newState = .waking
        } else if areDisplaysAsleep {
            newState = .displayAsleep
        } else if !isUserSessionActive || isScreenLocked {
            newState = .sessionInactive
        } else {
            newState = .interactive
        }

        guard state != newState else { return }
        state = newState
        AppLog.applicationActivity.info("Application activity changed: \(String(describing: newState), privacy: .public)")
        onStateChange?(newState)
    }
}
