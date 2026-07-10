import AppKit
import Foundation
import IOKit.pwr_mgt
import OSLog
import MacToolsPluginKit

@MainActor
protocol KeepAwakeSessionManaging: AnyObject {
    func start(until endDate: Date?, preventDisplaySleep: Bool) throws
    func requestStop(reason: KeepAwakeSession.EndReason)
}

@MainActor
final class KeepAwakeSession: KeepAwakeSessionManaging {
    enum EndReason {
        case userRequested
        case completed
    }

    private enum SessionError: LocalizedError {
        case invalidEndDate(PluginLocalization)
        case systemAssertionCreationFailed(IOReturn, PluginLocalization)
        case displayAssertionCreationFailed(IOReturn, PluginLocalization)

        var errorDescription: String? {
            switch self {
            case let .invalidEndDate(localization):
                return localization.string(
                    "error.invalidEndDate",
                    defaultValue: "自动停止时间必须晚于当前时间。"
                )
            case let .systemAssertionCreationFailed(result, localization):
                return localization.format(
                    "error.assertionCreationFailedFormat",
                    defaultValue: "无法启用阻止休眠，系统返回错误 %d。",
                    result
                )
            case let .displayAssertionCreationFailed(result, localization):
                return localization.format(
                    "error.displayAssertionCreationFailedFormat",
                    defaultValue: "无法保持屏幕常亮，系统返回错误 %d。",
                    result
                )
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "KeepAwakeSession")
    private let localization: PluginLocalization
    private let onEnd: (EndReason) -> Void

    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var autoStopTask: Task<Void, Never>?
    private var isStopping = false
    private var isObservingTermination = false

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onEnd: @escaping (EndReason) -> Void
    ) {
        self.localization = localization
        self.onEnd = onEnd
    }

    deinit {
        autoStopTask?.cancel()

        if systemAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(systemAssertionID)
        }

        if displayAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(displayAssertionID)
        }

        if isObservingTermination {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.willTerminateNotification,
                object: nil
            )
        }
    }

    func start(until endDate: Date?, preventDisplaySleep: Bool) throws {
        if systemAssertionID == IOPMAssertionID(0) {
            try createSystemAssertionIfNeeded()
        }

        try updateDisplayAssertion(preventDisplaySleep: preventDisplaySleep)
        try scheduleAutoStop(until: endDate)
        installTerminationObserverIfNeeded()
    }

    func requestStop(reason: EndReason) {
        finish(reason: reason)
    }

    private func installTerminationObserverIfNeeded() {
        guard !isObservingTermination else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        isObservingTermination = true
    }

    private func createSystemAssertionIfNeeded() throws {
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacTools Keep Awake" as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            logger.error("failed to create keep-awake system assertion result=\(result, privacy: .public)")
            throw SessionError.systemAssertionCreationFailed(result, localization)
        }

        systemAssertionID = newAssertionID
    }

    private func updateDisplayAssertion(preventDisplaySleep: Bool) throws {
        if preventDisplaySleep {
            if displayAssertionID == IOPMAssertionID(0) {
                try createDisplayAssertionIfNeeded()
            }
            return
        }

        releaseDisplayAssertionIfNeeded()
    }

    private func createDisplayAssertionIfNeeded() throws {
        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacTools Keep Awake Display" as CFString,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            logger.error("failed to create keep-awake display assertion result=\(result, privacy: .public)")
            throw SessionError.displayAssertionCreationFailed(result, localization)
        }

        displayAssertionID = newAssertionID
    }

    private func releaseDisplayAssertionIfNeeded() {
        guard displayAssertionID != IOPMAssertionID(0) else {
            return
        }

        let existingAssertionID = displayAssertionID
        displayAssertionID = IOPMAssertionID(0)

        let result = IOPMAssertionRelease(existingAssertionID)
        if result != kIOReturnSuccess {
            logger.error("failed to release keep-awake display assertion result=\(result, privacy: .public)")
        }
    }

    private func scheduleAutoStop(until endDate: Date?) throws {
        autoStopTask?.cancel()
        autoStopTask = nil

        guard let endDate else {
            return
        }

        let remainingDuration = endDate.timeIntervalSinceNow

        guard remainingDuration > 0 else {
            throw SessionError.invalidEndDate(localization)
        }

        autoStopTask = Task { [weak self] in
            let duration = UInt64(remainingDuration * 1_000_000_000)

            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }

            self?.finish(reason: .completed)
        }
    }

    private func finish(reason: EndReason) {
        guard !isStopping else {
            return
        }

        isStopping = true
        invalidateTerminationObserver()

        autoStopTask?.cancel()
        autoStopTask = nil

        releaseDisplayAssertionIfNeeded()

        if systemAssertionID != IOPMAssertionID(0) {
            let existingAssertionID = systemAssertionID
            systemAssertionID = IOPMAssertionID(0)

            let result = IOPMAssertionRelease(existingAssertionID)

            if result != kIOReturnSuccess {
                logger.error("failed to release keep-awake system assertion result=\(result, privacy: .public)")
            }
        }

        onEnd(reason)
    }

    private func invalidateTerminationObserver() {
        guard isObservingTermination else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        isObservingTermination = false
    }

    @objc
    private func handleAppWillTerminate() {
        requestStop(reason: .userRequested)
    }
}
