import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

private final class WeakBrightnessControllerRef: @unchecked Sendable {
    weak var value: DisplayBrightnessController?

    init(_ value: DisplayBrightnessController?) {
        self.value = value
    }
}

private final class BrightnessWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextWriteDate: [CGDirectDisplayID: Date] = [:]

    func waitTurn(for displayID: CGDirectDisplayID, minimumInterval: TimeInterval) {
        let delay = lock.withLock { () -> TimeInterval in
            let now = Date()
            let scheduledDate = max(now, nextWriteDate[displayID] ?? now)
            nextWriteDate[displayID] = scheduledDate.addingTimeInterval(minimumInterval)
            return max(0, scheduledDate.timeIntervalSince(now))
        }

        guard delay > 0 else {
            return
        }

        Thread.sleep(forTimeInterval: delay)
    }
}

@MainActor
final class DisplayBrightnessController: DisplayBrightnessControlling {
    private struct ManagedDisplay {
        var display: DisplayInfo
        var backend: any DisplayBrightnessBackend
        var currentBrightness: Double
        var lastCommittedBrightness: Double
        var pendingBrightness: Double?
        var writeInFlight = false
        var scheduledFlush: DispatchWorkItem?
        var pendingReadbackAfterWrite = false
    }

    var onStateChange: (() -> Void)?

    private let displayProvider: DisplayProviding
    private let backendBuilder: DisplayBrightnessBackendBuilding
    private let localization: PluginLocalization
    private let logger = DisplayBrightnessLog.controller
    private let shortWriteDelay: TimeInterval
    private let minimumWriteInterval: TimeInterval
    private let writeGate = BrightnessWriteGate()

    private var managedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var lastErrorMessage: String?
    private var terminateObserver: NSObjectProtocol?

    init(
        displayProvider: DisplayProviding = SystemDisplayService(),
        backendBuilder: DisplayBrightnessBackendBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortWriteDelay: TimeInterval = 0.08,
        minimumWriteInterval: TimeInterval = 0.08
    ) {
        self.displayProvider = displayProvider
        self.localization = localization
        self.backendBuilder = backendBuilder ?? SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: Arm64DDCServiceMatcher.resolveServices
        )
        self.shortWriteDelay = shortWriteDelay
        self.minimumWriteInterval = minimumWriteInterval

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupAll()
            }
        }
    }

    func refresh() {
        let displays = displayProvider.listConnectedDisplays()
        let previousBackends = Dictionary(
            uniqueKeysWithValues: managedDisplays.map { ($0.key, $0.value.backend) }
        )
        let nextBackends = backendBuilder.backends(for: displays, previous: previousBackends)
        let nextDisplayIDs = Set(displays.map(\.id))

        cleanupDisconnectedDisplays(keeping: nextDisplayIDs)

        var nextManagedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
        var nextDisplayOrder: [CGDirectDisplayID] = []

        for display in displays {
            guard let backend = nextBackends[display.id] else {
                continue
            }

            let previous = managedDisplays[display.id]
            let brightness = resolvedBrightness(for: display, backend: backend, previous: previous)

            nextManagedDisplays[display.id] = ManagedDisplay(
                display: display,
                backend: backend,
                currentBrightness: previous?.pendingBrightness ?? brightness,
                lastCommittedBrightness: brightness,
                pendingBrightness: previous?.pendingBrightness,
                writeInFlight: previous?.writeInFlight ?? false,
                scheduledFlush: previous?.scheduledFlush,
                pendingReadbackAfterWrite: previous?.pendingReadbackAfterWrite ?? false
            )
            nextDisplayOrder.append(display.id)
        }

        managedDisplays = nextManagedDisplays
        displayOrder = nextDisplayOrder

        if !nextManagedDisplays.isEmpty {
            lastErrorMessage = nil
        }
    }

    func snapshot() -> DisplayBrightnessSnapshot {
        let displays = displayOrder.compactMap { displayID -> DisplayBrightnessDisplay? in
            guard let managedDisplay = managedDisplays[displayID] else {
                return nil
            }

            return DisplayBrightnessDisplay(
                display: managedDisplay.display,
                brightness: managedDisplay.currentBrightness,
                isPendingWrite: managedDisplay.pendingBrightness != nil || managedDisplay.writeInFlight
            )
        }

        return DisplayBrightnessSnapshot(
            displays: displays,
            errorMessage: lastErrorMessage
        )
    }

    func setBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    ) {
        if managedDisplays[displayID] == nil {
            refresh()
        }

        guard var managedDisplay = managedDisplays[displayID] else {
            lastErrorMessage = DisplayBrightnessControllerError.displayUnavailable(
                displayID: displayID
            ).localizedDescription(localization: localization)
            onStateChange?()
            return
        }

        let clampedValue = Self.clamp(value)
        managedDisplay.currentBrightness = clampedValue
        managedDisplay.pendingBrightness = clampedValue
        managedDisplay.scheduledFlush?.cancel()
        managedDisplay.scheduledFlush = nil
        managedDisplay.pendingReadbackAfterWrite = phase == .ended
        lastErrorMessage = nil
        managedDisplays[displayID] = managedDisplay

        let delay = phase == .ended ? 0 : shortWriteDelay
        scheduleWrite(for: displayID, delay: delay)

        onStateChange?()
    }

    private func resolvedBrightness(
        for display: DisplayInfo,
        backend: any DisplayBrightnessBackend,
        previous: ManagedDisplay?
    ) -> Double {
        do {
            return Self.clamp(try backend.readBrightness())
        } catch {
            if let previous {
                return previous.currentBrightness
            }

            logger.error(
                "failed to read brightness for \(display.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return 1
        }
    }

    private func scheduleWrite(for displayID: CGDirectDisplayID, delay: TimeInterval) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        let controllerRef = WeakBrightnessControllerRef(self)
        let workItem = Self.makeScheduledWriteWorkItem(
            controllerRef: controllerRef,
            displayID: displayID
        )

        managedDisplay.scheduledFlush = workItem
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func beginWriteIfNeeded(for displayID: CGDirectDisplayID) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        guard !managedDisplay.writeInFlight, let targetValue = managedDisplay.pendingBrightness else {
            return
        }

        managedDisplay.writeInFlight = true
        managedDisplay.pendingBrightness = nil
        managedDisplay.scheduledFlush = nil
        let needsReadback = managedDisplay.pendingReadbackAfterWrite
        managedDisplay.pendingReadbackAfterWrite = false
        let backend = managedDisplay.backend
        let displayName = managedDisplay.display.name
        let controllerRef = WeakBrightnessControllerRef(self)
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).async(
            execute: Self.makeWriteWorkItem(
                controllerRef: controllerRef,
                backend: backend,
                displayID: displayID,
                targetValue: targetValue,
                needsReadback: needsReadback,
                displayName: displayName,
                writeGate: writeGate,
                minimumWriteInterval: minimumWriteInterval
            )
        )
    }

    private func finishWrite(
        for displayID: CGDirectDisplayID,
        targetValue: Double,
        readbackValue: Double?,
        displayName: String,
        result: Result<Void, Error>
    ) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        managedDisplay.writeInFlight = false

        switch result {
        case .success:
            let committedBrightness = readbackValue.map(Self.clamp) ?? targetValue
            managedDisplay.lastCommittedBrightness = committedBrightness
            if managedDisplay.pendingBrightness == nil {
                managedDisplay.currentBrightness = committedBrightness
            }
            lastErrorMessage = nil
        case .failure(let error):
            let localizedDescription = localizedDescription(for: error)
            logger.error(
                "write failed for \(displayName, privacy: .public): \(localizedDescription, privacy: .public)"
            )

            if let fallbackBackend = fallbackBackend(for: displayID, failedBackend: managedDisplay.backend) {
                logger.info(
                    "retrying brightness write for \(displayName, privacy: .public) with \(String(describing: fallbackBackend.kind), privacy: .public) fallback"
                )
                let retryBrightness = managedDisplay.pendingBrightness ?? targetValue
                managedDisplay.backend.cleanup()
                managedDisplay.backend = fallbackBackend
                managedDisplay.pendingBrightness = retryBrightness
                managedDisplay.pendingReadbackAfterWrite = true
                managedDisplay.currentBrightness = retryBrightness
                lastErrorMessage = nil
            } else {
                if managedDisplay.pendingBrightness == nil {
                    managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
                }

                lastErrorMessage = localization.format(
                    "error.adjustFailedFormat",
                    defaultValue: "调节失败：%@",
                    localizedDescription
                )
            }
        }

        managedDisplays[displayID] = managedDisplay
        onStateChange?()

        if managedDisplay.pendingBrightness != nil {
            scheduleWrite(for: displayID, delay: 0)
        }
    }

    private func localizedDescription(for error: Error) -> String {
        guard let brightnessError = error as? DisplayBrightnessControllerError else {
            return error.localizedDescription
        }

        return brightnessError.localizedDescription(localization: localization)
    }

    private func fallbackBackend(
        for displayID: CGDirectDisplayID,
        failedBackend: any DisplayBrightnessBackend
    ) -> (any DisplayBrightnessBackend)? {
        guard let managedDisplay = managedDisplays[displayID] else {
            return nil
        }

        let previousBackends = Dictionary(
            uniqueKeysWithValues: managedDisplays.map { ($0.key, $0.value.backend) }
        )
        return backendBuilder.fallbackBackend(
            after: failedBackend,
            for: managedDisplay.display,
            previous: previousBackends
        )
    }

    private func cleanupDisconnectedDisplays(keeping displayIDs: Set<CGDirectDisplayID>) {
        for (displayID, managedDisplay) in managedDisplays where !displayIDs.contains(displayID) {
            managedDisplay.scheduledFlush?.cancel()
            managedDisplay.backend.cleanup()
        }
    }

    private func cleanupAll() {
        for (_, managedDisplay) in managedDisplays {
            managedDisplay.scheduledFlush?.cancel()
            managedDisplay.backend.cleanup()
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    nonisolated private static func makeScheduledWriteWorkItem(
        controllerRef: WeakBrightnessControllerRef,
        displayID: CGDirectDisplayID
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            Task { @MainActor in
                controllerRef.value?.beginWriteIfNeeded(for: displayID)
            }
        }
    }

    nonisolated private static func makeWriteWorkItem(
        controllerRef: WeakBrightnessControllerRef,
        backend: any DisplayBrightnessBackend,
        displayID: CGDirectDisplayID,
        targetValue: Double,
        needsReadback: Bool,
        displayName: String,
        writeGate: BrightnessWriteGate,
        minimumWriteInterval: TimeInterval
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result: Result<Void, Error>
            var readbackValue: Double?

            do {
                writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                try backend.writeBrightness(targetValue)
                if needsReadback {
                    readbackValue = try? backend.readBrightness()
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            Task { @MainActor in
                controllerRef.value?.finishWrite(
                    for: displayID,
                    targetValue: targetValue,
                    readbackValue: readbackValue,
                    displayName: displayName,
                    result: result
                )
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }

        return try body()
    }
}
