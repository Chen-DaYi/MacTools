import Foundation
import IOKit.ps

struct KeepAwakePowerSourceState: Equatable {
    let isPortableMac: Bool
    let isOnExternalPower: Bool

    var canPreventLidCloseSleep: Bool {
        isPortableMac && isOnExternalPower
    }
}

@MainActor
protocol KeepAwakePowerSourceMonitoring: AnyObject {
    var currentState: KeepAwakePowerSourceState { get }
    var onChange: ((KeepAwakePowerSourceState) -> Void)? { get set }

    func start()
    func stop()
}

@MainActor
final class KeepAwakePowerSourceMonitor: KeepAwakePowerSourceMonitoring {
    private final class RunLoopSourceHolder: @unchecked Sendable {
        let source: CFRunLoopSource

        init(source: CFRunLoopSource) {
            self.source = source
        }

        deinit {
            CFRunLoopSourceInvalidate(source)
        }
    }

    private(set) var currentState: KeepAwakePowerSourceState
    var onChange: ((KeepAwakePowerSourceState) -> Void)?

    private var runLoopSourceHolder: RunLoopSourceHolder?

    init() {
        currentState = Self.readCurrentState()
    }

    func start() {
        refresh()

        guard runLoopSourceHolder == nil else {
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
            Self.powerSourceDidChange,
            context
        ) else {
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        runLoopSourceHolder = RunLoopSourceHolder(source: source)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let runLoopSourceHolder else {
            return
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            runLoopSourceHolder.source,
            .commonModes
        )
        CFRunLoopSourceInvalidate(runLoopSourceHolder.source)
        self.runLoopSourceHolder = nil
    }

    private func refresh() {
        let newState = Self.readCurrentState()
        guard newState != currentState else {
            return
        }

        currentState = newState
        onChange?(newState)
    }

    private static let powerSourceDidChange: IOPowerSourceCallbackType = { context in
        guard let context else {
            return
        }

        let monitor = Unmanaged<KeepAwakePowerSourceMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            monitor.refresh()
        }
    }

    private static func readCurrentState() -> KeepAwakePowerSourceState {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: false
            )
        }

        let isPortableMac = sources.contains { source in
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                return false
            }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }

        let providingPowerSource = IOPSGetProvidingPowerSourceType(info)?
            .takeUnretainedValue() as String?

        return KeepAwakePowerSourceState(
            isPortableMac: isPortableMac,
            isOnExternalPower: providingPowerSource == kIOPSACPowerValue
        )
    }
}
