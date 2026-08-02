import Foundation
import IOKit.pwr_mgt
import MacToolsPluginKit

@MainActor
protocol KeepAwakeUserActivityMaintaining: AnyObject {
    var isActive: Bool { get }
    var onFailure: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
}

@MainActor
final class KeepAwakeUserActivityMaintainer: KeepAwakeUserActivityMaintaining {
    typealias ActivityDeclarer = (inout IOPMAssertionID) -> IOReturn
    typealias AssertionReleaser = (IOPMAssertionID) -> IOReturn

    private enum Timing {
        static let refreshInterval: TimeInterval = 30
    }

    private struct UserActivityError: LocalizedError {
        let result: IOReturn
        let localization: PluginLocalization

        var errorDescription: String? {
            localization.format(
                "error.automaticLock.userActivityFailedFormat",
                defaultValue: "无法阻止自动锁定，系统返回错误 %d。",
                result
            )
        }
    }

    var onFailure: ((Error) -> Void)?

    var isActive: Bool {
        refreshTimer != nil
    }

    private let localization: PluginLocalization
    private let refreshInterval: TimeInterval
    private let declareActivity: ActivityDeclarer
    private let releaseAssertion: AssertionReleaser
    private var activityAssertionID = IOPMAssertionID(0)
    private var refreshTimer: Timer?

    init(
        localization: PluginLocalization,
        refreshInterval: TimeInterval = Timing.refreshInterval,
        activityDeclarer: ActivityDeclarer? = nil,
        assertionReleaser: AssertionReleaser? = nil
    ) {
        self.localization = localization
        self.refreshInterval = refreshInterval
        self.declareActivity = activityDeclarer ?? { assertionID in
            IOPMAssertionDeclareUserActivity(
                "MacTools Screen-Based Tools" as CFString,
                kIOPMUserActiveRemote,
                &assertionID
            )
        }
        self.releaseAssertion = assertionReleaser ?? { assertionID in
            IOPMAssertionRelease(assertionID)
        }
    }

    isolated deinit {
        refreshTimer?.invalidate()
        if activityAssertionID != IOPMAssertionID(0) {
            _ = releaseAssertion(activityAssertionID)
        }
    }

    func start() throws {
        guard !isActive else {
            return
        }

        try reportUserActivity()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUserActivity()
            }
        }
        timer.tolerance = min(1, refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard activityAssertionID != IOPMAssertionID(0) else {
            return
        }

        let result = releaseAssertion(activityAssertionID)
        guard result == kIOReturnSuccess else {
            onFailure?(UserActivityError(result: result, localization: localization))
            return
        }
        activityAssertionID = IOPMAssertionID(0)
    }

    private func refreshUserActivity() {
        do {
            try reportUserActivity()
        } catch {
            stop()
            onFailure?(error)
        }
    }

    private func reportUserActivity() throws {
        let result = declareActivity(&activityAssertionID)
        guard result == kIOReturnSuccess else {
            throw UserActivityError(result: result, localization: localization)
        }
    }
}
