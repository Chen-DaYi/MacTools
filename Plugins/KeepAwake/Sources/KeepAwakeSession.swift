import AppKit
import Foundation
import IOKit.pwr_mgt
import OSLog
import MacToolsPluginKit

@MainActor
protocol KeepAwakeSessionManaging: AnyObject {
    func start(
        until endDate: Date?,
        preventDisplaySleep: Bool,
        preventLidCloseSleep: Bool
    ) throws
    func setPreventDisplaySleep(_ preventDisplaySleep: Bool) throws
    func setPreventLidCloseSleep(_ preventLidCloseSleep: Bool) throws
    func requestStop(reason: KeepAwakeSession.EndReason)
}

@MainActor
final class KeepAwakeSession: KeepAwakeSessionManaging {
    enum AssertionKind: Equatable {
        case system
        case display
        case lidClose

        var type: CFString {
            switch self {
            case .system:
                return kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            case .display:
                return kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            case .lidClose:
                // Matches `caffeinate -s`. powerd honors this assertion only while
                // the Mac is connected to an unlimited external power source.
                return "PreventSystemSleep" as CFString
            }
        }

        var name: CFString {
            switch self {
            case .system:
                return "MacTools Keep Awake" as CFString
            case .display:
                return "MacTools Keep Awake Display" as CFString
            case .lidClose:
                return "MacTools Keep Awake Closed Lid" as CFString
            }
        }
    }

    typealias AssertionCreator = (AssertionKind) -> (result: IOReturn, assertionID: IOPMAssertionID)
    typealias AssertionReleaser = (IOPMAssertionID) -> IOReturn

    // IOKit releases are safe during nonisolated teardown; tests inject equivalent deterministic operations.
    private final class AssertionOperations: @unchecked Sendable {
        private let creator: AssertionCreator
        private let releaser: AssertionReleaser

        init(creator: @escaping AssertionCreator, releaser: @escaping AssertionReleaser) {
            self.creator = creator
            self.releaser = releaser
        }

        func create(_ kind: AssertionKind) -> (result: IOReturn, assertionID: IOPMAssertionID) {
            creator(kind)
        }

        func release(_ assertionID: IOPMAssertionID) -> IOReturn {
            releaser(assertionID)
        }
    }

    enum EndReason {
        case userRequested
        case completed
    }

    private enum SessionError: LocalizedError {
        case invalidEndDate(PluginLocalization)
        case systemAssertionCreationFailed(IOReturn, PluginLocalization)
        case displayAssertionCreationFailed(IOReturn, PluginLocalization)
        case displayAssertionReleaseFailed(IOReturn, PluginLocalization)
        case lidCloseAssertionCreationFailed(IOReturn, PluginLocalization)
        case lidCloseAssertionReleaseFailed(IOReturn, PluginLocalization)

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
            case let .displayAssertionReleaseFailed(result, localization):
                return localization.format(
                    "error.displayAssertionReleaseFailedFormat",
                    defaultValue: "无法允许屏幕关闭，系统返回错误 %d。",
                    result
                )
            case let .lidCloseAssertionCreationFailed(result, localization):
                return localization.format(
                    "error.lidCloseAssertionCreationFailedFormat",
                    defaultValue: "无法启用合盖保持唤醒，系统返回错误 %d。",
                    result
                )
            case let .lidCloseAssertionReleaseFailed(result, localization):
                return localization.format(
                    "error.lidCloseAssertionReleaseFailedFormat",
                    defaultValue: "无法关闭合盖保持唤醒，系统返回错误 %d。",
                    result
                )
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "KeepAwakeSession")
    private let localization: PluginLocalization
    private let onEnd: (EndReason) -> Void
    private let assertionOperations: AssertionOperations

    private var systemAssertionID = IOPMAssertionID(0)
    private var displayAssertionID = IOPMAssertionID(0)
    private var lidCloseAssertionID = IOPMAssertionID(0)
    private var autoStopTask: Task<Void, Never>?
    private var isStopping = false
    private var isObservingTermination = false

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onEnd: @escaping (EndReason) -> Void,
        assertionCreator: AssertionCreator? = nil,
        assertionReleaser: AssertionReleaser? = nil
    ) {
        self.localization = localization
        self.onEnd = onEnd
        let resolvedCreator: AssertionCreator = assertionCreator ?? { kind in
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kind.type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                kind.name,
                &assertionID
            )
            return (result, assertionID)
        }
        let resolvedReleaser: AssertionReleaser = assertionReleaser ?? { assertionID in
            IOPMAssertionRelease(assertionID)
        }
        self.assertionOperations = AssertionOperations(
            creator: resolvedCreator,
            releaser: resolvedReleaser
        )
    }

    deinit {
        autoStopTask?.cancel()

        if systemAssertionID != IOPMAssertionID(0) {
            _ = assertionOperations.release(systemAssertionID)
        }

        if displayAssertionID != IOPMAssertionID(0) {
            _ = assertionOperations.release(displayAssertionID)
        }

        if lidCloseAssertionID != IOPMAssertionID(0) {
            _ = assertionOperations.release(lidCloseAssertionID)
        }

        if isObservingTermination {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.willTerminateNotification,
                object: nil
            )
        }
    }

    func start(
        until endDate: Date?,
        preventDisplaySleep: Bool,
        preventLidCloseSleep: Bool
    ) throws {
        if systemAssertionID == IOPMAssertionID(0) {
            try createSystemAssertionIfNeeded()
        }

        try updateLidCloseAssertion(preventLidCloseSleep: preventLidCloseSleep)

        do {
            try updateDisplayAssertion(preventDisplaySleep: preventDisplaySleep)
        } catch {
            logger.error("failed to update keep-awake display assertion at session start: \(error.localizedDescription, privacy: .public)")
        }
        try scheduleAutoStop(until: endDate)
        installTerminationObserverIfNeeded()
    }

    func setPreventDisplaySleep(_ preventDisplaySleep: Bool) throws {
        try updateDisplayAssertion(preventDisplaySleep: preventDisplaySleep)
    }

    func setPreventLidCloseSleep(_ preventLidCloseSleep: Bool) throws {
        try updateLidCloseAssertion(preventLidCloseSleep: preventLidCloseSleep)
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
        let creation = assertionOperations.create(.system)

        guard creation.result == kIOReturnSuccess else {
            logger.error("failed to create keep-awake system assertion result=\(creation.result, privacy: .public)")
            throw SessionError.systemAssertionCreationFailed(creation.result, localization)
        }

        systemAssertionID = creation.assertionID
    }

    private func updateDisplayAssertion(preventDisplaySleep: Bool) throws {
        if preventDisplaySleep {
            if displayAssertionID == IOPMAssertionID(0) {
                try createDisplayAssertionIfNeeded()
            }
            return
        }

        try releaseDisplayAssertionIfNeeded()
    }

    private func createDisplayAssertionIfNeeded() throws {
        let creation = assertionOperations.create(.display)

        guard creation.result == kIOReturnSuccess else {
            logger.error("failed to create keep-awake display assertion result=\(creation.result, privacy: .public)")
            throw SessionError.displayAssertionCreationFailed(creation.result, localization)
        }

        displayAssertionID = creation.assertionID
    }

    private func releaseDisplayAssertionIfNeeded() throws {
        guard displayAssertionID != IOPMAssertionID(0) else {
            return
        }

        let existingAssertionID = displayAssertionID
        let result = assertionOperations.release(existingAssertionID)
        guard result == kIOReturnSuccess else {
            logger.error("failed to release keep-awake display assertion result=\(result, privacy: .public)")
            throw SessionError.displayAssertionReleaseFailed(result, localization)
        }

        displayAssertionID = IOPMAssertionID(0)
    }

    private func updateLidCloseAssertion(preventLidCloseSleep: Bool) throws {
        if preventLidCloseSleep {
            if lidCloseAssertionID == IOPMAssertionID(0) {
                try createLidCloseAssertionIfNeeded()
            }
            return
        }

        try releaseLidCloseAssertionIfNeeded()
    }

    private func createLidCloseAssertionIfNeeded() throws {
        let creation = assertionOperations.create(.lidClose)

        guard creation.result == kIOReturnSuccess else {
            logger.error("failed to create closed-lid assertion result=\(creation.result, privacy: .public)")
            throw SessionError.lidCloseAssertionCreationFailed(creation.result, localization)
        }

        lidCloseAssertionID = creation.assertionID
    }

    private func releaseLidCloseAssertionIfNeeded() throws {
        guard lidCloseAssertionID != IOPMAssertionID(0) else {
            return
        }

        let existingAssertionID = lidCloseAssertionID
        let result = assertionOperations.release(existingAssertionID)
        guard result == kIOReturnSuccess else {
            logger.error("failed to release closed-lid assertion result=\(result, privacy: .public)")
            throw SessionError.lidCloseAssertionReleaseFailed(result, localization)
        }

        lidCloseAssertionID = IOPMAssertionID(0)
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

        try? releaseDisplayAssertionIfNeeded()
        try? releaseLidCloseAssertionIfNeeded()

        if systemAssertionID != IOPMAssertionID(0) {
            let existingAssertionID = systemAssertionID
            systemAssertionID = IOPMAssertionID(0)

            let result = assertionOperations.release(existingAssertionID)

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
