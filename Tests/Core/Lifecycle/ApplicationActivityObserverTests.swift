import AppKit
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class ApplicationActivityObserverTests: XCTestCase {
    func testIndependentSleepSignalsDoNotResumeUntilSessionIsInteractive() async {
        let center = NotificationCenter()
        let observer = SystemApplicationActivityObserver(
            notificationCenter: center,
            wakeSettleDelay: .milliseconds(20),
            initialSignals: .interactive,
            currentSignalsProvider: {
                ApplicationActivitySignals(
                    isUserSessionActive: false,
                    isScreenLocked: false,
                    areDisplaysAsleep: false
                )
            }
        )

        await post(
            NSWorkspace.sessionDidResignActiveNotification,
            to: center,
            observer: observer,
            expecting: .sessionInactive
        )
        await post(
            NSWorkspace.screensDidSleepNotification,
            to: center,
            observer: observer,
            expecting: .displayAsleep
        )
        await post(
            NSWorkspace.willSleepNotification,
            to: center,
            observer: observer,
            expecting: .systemSleeping
        )
        await post(
            NSWorkspace.didWakeNotification,
            to: center,
            observer: observer,
            expecting: .waking
        )

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(observer.state, .sessionInactive)

        await post(
            NSWorkspace.sessionDidBecomeActiveNotification,
            to: center,
            observer: observer,
            expecting: .interactive
        )
    }

    func testDisplaySleepAlonePausesAndResumesBackgroundWork() async {
        let center = NotificationCenter()
        let observer = SystemApplicationActivityObserver(
            notificationCenter: center,
            initialSignals: .interactive,
            currentSignalsProvider: { .interactive }
        )

        await post(
            NSWorkspace.screensDidSleepNotification,
            to: center,
            observer: observer,
            expecting: .displayAsleep
        )
        await post(
            NSWorkspace.screensDidWakeNotification,
            to: center,
            observer: observer,
            expecting: .interactive
        )
    }

    func testInitialSignalsReflectLockedSessionBeforeNotificationsArrive() {
        let observer = SystemApplicationActivityObserver(
            notificationCenter: NotificationCenter(),
            initialSignals: ApplicationActivitySignals(
                isUserSessionActive: true,
                isScreenLocked: true,
                areDisplaysAsleep: false
            )
        )

        XCTAssertEqual(observer.state, .sessionInactive)
    }

    func testInitialSignalsPrioritizeSleepingDisplays() {
        let observer = SystemApplicationActivityObserver(
            notificationCenter: NotificationCenter(),
            initialSignals: ApplicationActivitySignals(
                isUserSessionActive: false,
                isScreenLocked: true,
                areDisplaysAsleep: true
            )
        )

        XCTAssertEqual(observer.state, .displayAsleep)
    }

    func testWillSleepTakesEffectBeforeNotificationReturns() {
        let center = NotificationCenter()
        let observer = SystemApplicationActivityObserver(
            notificationCenter: center,
            initialSignals: .interactive
        )

        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(observer.state, .systemSleeping)
    }

    func testRuntimeScreenLockPausesAndUnlockResumesBackgroundWork() async {
        let workspaceCenter = NotificationCenter()
        let screenLockCenter = NotificationCenter()
        let observer = SystemApplicationActivityObserver(
            notificationCenter: workspaceCenter,
            screenLockNotificationCenter: screenLockCenter,
            initialSignals: .interactive,
            currentSignalsProvider: { .interactive }
        )

        await post(
            ApplicationActivityNotificationName.screenDidLock,
            to: screenLockCenter,
            observer: observer,
            expecting: .sessionInactive
        )
        await post(
            ApplicationActivityNotificationName.screenDidUnlock,
            to: screenLockCenter,
            observer: observer,
            expecting: .interactive
        )
    }

    func testWakeSettlementRechecksLockedSessionBeforeResuming() async {
        let workspaceCenter = NotificationCenter()
        let lockedSignals = ApplicationActivitySignals(
            isUserSessionActive: true,
            isScreenLocked: true,
            areDisplaysAsleep: false
        )
        let observer = SystemApplicationActivityObserver(
            notificationCenter: workspaceCenter,
            wakeSettleDelay: .milliseconds(20),
            initialSignals: .interactive,
            currentSignalsProvider: { lockedSignals }
        )

        await post(
            NSWorkspace.willSleepNotification,
            to: workspaceCenter,
            observer: observer,
            expecting: .systemSleeping
        )
        await post(
            NSWorkspace.didWakeNotification,
            to: workspaceCenter,
            observer: observer,
            expecting: .waking
        )

        let settlement = expectation(description: "wake settlement rechecks locked session")
        observer.onStateChange = { state in
            if state == .sessionInactive {
                settlement.fulfill()
            }
        }
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await fulfillment(of: [settlement], timeout: 1)

        XCTAssertEqual(observer.state, .sessionInactive)
    }

    private func post(
        _ name: Notification.Name,
        to center: NotificationCenter,
        observer: SystemApplicationActivityObserver,
        expecting expectedState: PluginApplicationActivityState
    ) async {
        let expectation = expectation(description: "activity becomes \(expectedState)")
        observer.onStateChange = { state in
            if state == expectedState {
                expectation.fulfill()
            }
        }
        center.post(name: name, object: nil)
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(observer.state, expectedState)
    }
}
