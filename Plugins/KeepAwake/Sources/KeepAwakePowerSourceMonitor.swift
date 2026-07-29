import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

struct KeepAwakePowerSourceState: Equatable {
    let isPortableMac: Bool
    let isOnExternalPower: Bool
    let isLidClosed: Bool

    var canPreventLidCloseSleep: Bool {
        isPortableMac && isOnExternalPower
    }

    var canRunVirtualDisplay: Bool {
        canPreventLidCloseSleep && isLidClosed
    }

    init(
        isPortableMac: Bool,
        isOnExternalPower: Bool,
        isLidClosed: Bool = false
    ) {
        self.isPortableMac = isPortableMac
        self.isOnExternalPower = isOnExternalPower
        self.isLidClosed = isLidClosed
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
    private enum Clamshell {
        static let rootDomainClass = "IOPMrootDomain"
        static let stateProperty = "AppleClamshellState"

        // kIOPMMessageClamshellStateChange is a public C macro that Swift
        // cannot import because its definition expands through other macros.
        static let stateChangeMessage: natural_t = 0xe003_4100
    }

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
    private var clamshellNotificationPort: IONotificationPortRef?
    private var clamshellNotification: io_object_t = IO_OBJECT_NULL

    init() {
        currentState = Self.readCurrentState()
    }

    func start() {
        startClamshellObserver()

        if runLoopSourceHolder == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let unmanagedSource = IOPSNotificationCreateRunLoopSource(
                Self.powerSourceDidChange,
                context
            ) {
                let source = unmanagedSource.takeRetainedValue()
                runLoopSourceHolder = RunLoopSourceHolder(source: source)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }

        refresh()
    }

    func stop() {
        if let runLoopSourceHolder {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSourceHolder.source,
                .commonModes
            )
            CFRunLoopSourceInvalidate(runLoopSourceHolder.source)
            self.runLoopSourceHolder = nil
        }

        stopClamshellObserver()
    }

    private func refresh(isLidClosed: Bool? = nil) {
        let newState = Self.readCurrentState(isLidClosed: isLidClosed)
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

    private func startClamshellObserver() {
        guard clamshellNotificationPort == nil else {
            return
        }

        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Clamshell.rootDomainClass)
        )
        guard rootDomain != IO_OBJECT_NULL else {
            return
        }
        defer { IOObjectRelease(rootDomain) }

        guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }

        if let source = IONotificationPortGetRunLoopSource(notificationPort)?
            .takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        var notification = io_object_t(IO_OBJECT_NULL)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            notificationPort,
            rootDomain,
            kIOGeneralInterest,
            Self.clamshellStateDidChange,
            context,
            &notification
        )

        guard result == KERN_SUCCESS else {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?
                .takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(notificationPort)
            return
        }

        clamshellNotificationPort = notificationPort
        clamshellNotification = notification
    }

    private func stopClamshellObserver() {
        if clamshellNotification != IO_OBJECT_NULL {
            IOObjectRelease(clamshellNotification)
            clamshellNotification = IO_OBJECT_NULL
        }

        guard let notificationPort = clamshellNotificationPort else {
            return
        }

        if let source = IONotificationPortGetRunLoopSource(notificationPort)?
            .takeUnretainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        IONotificationPortDestroy(notificationPort)
        clamshellNotificationPort = nil
    }

    private static let clamshellStateDidChange: IOServiceInterestCallback = {
        context,
        _,
        messageType,
        messageArgument in
        guard
            messageType == Clamshell.stateChangeMessage,
            let context
        else {
            return
        }

        let stateBits = messageArgument.map { UInt(bitPattern: $0) } ?? 0
        let isLidClosed = (stateBits & UInt(kClamshellStateBit)) != 0
        let monitor = Unmanaged<KeepAwakePowerSourceMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        Task { @MainActor in
            monitor.refresh(isLidClosed: isLidClosed)
        }
    }

    private static func readCurrentState(
        isLidClosed lidStateOverride: Bool? = nil
    ) -> KeepAwakePowerSourceState {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: false,
                isLidClosed: false
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
            isOnExternalPower: providingPowerSource == kIOPSACPowerValue,
            isLidClosed: isPortableMac
                && (lidStateOverride ?? readCurrentLidState())
        )
    }

    private static func readCurrentLidState() -> Bool {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Clamshell.rootDomainClass)
        )
        guard rootDomain != IO_OBJECT_NULL else {
            return false
        }
        defer { IOObjectRelease(rootDomain) }

        return IORegistryEntryCreateCFProperty(
            rootDomain,
            Clamshell.stateProperty as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool ?? false
    }
}
