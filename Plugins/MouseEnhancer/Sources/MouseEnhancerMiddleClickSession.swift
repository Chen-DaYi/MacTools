import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
import MacToolsPluginKit
import MultitouchSupport
import OSLog

@MainActor
protocol MouseEnhancerMiddleClickSessionManaging: AnyObject {
    var requiredFingerCount: Int { get set }

    func activate()
    func deactivate()
}

final class MouseEnhancerMultitouchRuntime: @unchecked Sendable {
    typealias CreateDeviceListFunction = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias RegisterCallbackFunction = @convention(c) (MTDevice, MTFrameCallbackFunction) -> Bool
    typealias UnregisterCallbackFunction = @convention(c) (MTDevice, MTFrameCallbackFunction) -> Bool
    typealias StartDeviceFunction = @convention(c) (MTDevice, Int32) -> Void
    typealias StopDeviceFunction = @convention(c) (MTDevice) -> Void
    typealias ReleaseDeviceFunction = @convention(c) (MTDevice) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let libraryHandle: UnsafeMutableRawPointer
    private let createDeviceListFunction: CreateDeviceListFunction
    private let registerCallbackFunction: RegisterCallbackFunction
    private let unregisterCallbackFunction: UnregisterCallbackFunction
    private let startDeviceFunction: StartDeviceFunction
    private let stopDeviceFunction: StopDeviceFunction
    private let releaseDeviceFunction: ReleaseDeviceFunction

    static func load() -> MouseEnhancerMultitouchRuntime? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard
            let createDeviceList: CreateDeviceListFunction = loadSymbol(
                "MTDeviceCreateList", from: handle
            ),
            let registerCallback: RegisterCallbackFunction = loadSymbol(
                "MTRegisterContactFrameCallback", from: handle
            ),
            let unregisterCallback: UnregisterCallbackFunction = loadSymbol(
                "MTUnregisterContactFrameCallback", from: handle
            ),
            let startDevice: StartDeviceFunction = loadSymbol("MTDeviceStart", from: handle),
            let stopDevice: StopDeviceFunction = loadSymbol("MTDeviceStop", from: handle),
            let releaseDevice: ReleaseDeviceFunction = loadSymbol("MTDeviceRelease", from: handle)
        else {
            dlclose(handle)
            return nil
        }
        return MouseEnhancerMultitouchRuntime(
            libraryHandle: handle,
            createDeviceListFunction: createDeviceList,
            registerCallbackFunction: registerCallback,
            unregisterCallbackFunction: unregisterCallback,
            startDeviceFunction: startDevice,
            stopDeviceFunction: stopDevice,
            releaseDeviceFunction: releaseDevice
        )
    }

    private static func loadSymbol<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> Function? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }

    private init(
        libraryHandle: UnsafeMutableRawPointer,
        createDeviceListFunction: CreateDeviceListFunction,
        registerCallbackFunction: RegisterCallbackFunction,
        unregisterCallbackFunction: UnregisterCallbackFunction,
        startDeviceFunction: StartDeviceFunction,
        stopDeviceFunction: StopDeviceFunction,
        releaseDeviceFunction: ReleaseDeviceFunction
    ) {
        self.libraryHandle = libraryHandle
        self.createDeviceListFunction = createDeviceListFunction
        self.registerCallbackFunction = registerCallbackFunction
        self.unregisterCallbackFunction = unregisterCallbackFunction
        self.startDeviceFunction = startDeviceFunction
        self.stopDeviceFunction = stopDeviceFunction
        self.releaseDeviceFunction = releaseDeviceFunction
    }

    deinit {
        dlclose(libraryHandle)
    }

    func createDeviceList() -> [MTDevice] {
        createDeviceListFunction()?.takeUnretainedValue() as? [MTDevice] ?? []
    }

    func register(_ device: MTDevice, callback: MTFrameCallbackFunction) {
        _ = registerCallbackFunction(device, callback)
    }

    func unregister(_ device: MTDevice, callback: MTFrameCallbackFunction) {
        _ = unregisterCallbackFunction(device, callback)
    }

    func start(_ device: MTDevice) {
        startDeviceFunction(device, 0)
    }

    func stop(_ device: MTDevice) {
        stopDeviceFunction(device)
    }

    func release(_ device: MTDevice) {
        releaseDeviceFunction(device)
    }
}

/// Manages trackpad multitouch callbacks and converts a system left-click into a middle-click
/// in place through a CGEvent tap when the configured finger count is detected.
///
/// Behavior follows the tap-to-click mode from MiddleClick:
/// - The multitouch callback maintains the `threeDown` flag for the configured finger contact.
/// - The CGEvent tap intercepts `leftMouseDown/Up` on the main thread and rewrites them to
///   `otherMouseDown/Up` while that contact is active.
/// - The left-click produced by the system tap-to-click gesture is converted before apps receive it,
///   without synthesizing an extra event or causing a double-click.
///
/// Recovery hooks match artginzburg/MiddleClick:
/// - `didWakeNotification`: after wake, the multitouch driver may not be ready; rebuild listeners
///   after a delay.
/// - `CGDisplayRegisterReconfigurationCallback`: also schedule a rebuild after display changes.
/// - IOKit `AppleMultitouchDevice` first-match notification: rebuild when built-in or external
///   trackpads are re-enumerated.
///
/// Mutable state is read and written both by multitouch / CGEvent tap C callback threads and by the
/// main thread, so the type is explicitly marked `@unchecked Sendable`. All lifecycle methods
/// (`start`, `stop`, `activate`, `deactivate`) and internal restart scheduling are expected to run
/// on the main thread.
final class MouseEnhancerMiddleClickSession: MouseEnhancerMiddleClickSessionManaging, @unchecked Sendable {
    private typealias CallbackContext = PluginCallbackContext<MouseEnhancerMiddleClickSession>

    // MARK: - CGEvent Tap State (read and written by CGEvent tap and C callback threads)

    /// Whether the required finger count is currently touching the trackpad.
    nonisolated(unsafe) var threeDown = false
    /// Whether the event tap converted a `leftMouseDown` to `otherMouseDown` and is waiting for its matching Up.
    nonisolated(unsafe) var wasThreeDown = false

    // MARK: - Config (set on the main thread, read from callback threads)

    nonisolated(unsafe) var requiredFingerCount: Int = 3

    // MARK: - Infrastructure

    private var devices: [MTDevice] = []
    private var eventTap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var eventTapCallbackPointer: UnsafeMutableRawPointer?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioIterator: io_iterator_t = 0
    private var ioCallbackPointer: UnsafeMutableRawPointer?
    private var displayCallbackRegistered = false
    private var displayCallbackPointer: UnsafeMutableRawPointer?
    private var restartWorkItem: DispatchWorkItem?
    private let multitouchRuntime: MouseEnhancerMultitouchRuntime?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "MouseEnhancerMiddleClickSession")

    /// After wake, the multitouch driver may not be ready; delay before rebuilding listeners.
    /// Keep this aligned with artginzburg/MiddleClick at 10 seconds: long sleep can make driver
    /// re-enumeration vary across hardware, and 2-3 second delays reproduced "MiddleClick stopped
    /// working" in testing. Users rarely need middle-click in the first few seconds after unlock.
    private static let wakeRestartDelay: TimeInterval = 10

    // MARK: - Singleton Reference (for C callback access)

    nonisolated(unsafe) static weak var activeSession: MouseEnhancerMiddleClickSession?

    init(multitouchRuntime: MouseEnhancerMultitouchRuntime? = .load()) {
        self.multitouchRuntime = multitouchRuntime
    }

    // MARK: - Multitouch Callback
    //
    // Maintains only the `threeDown` flag; no gesture recognition is performed here.

    private let touchCallback: MTFrameCallbackFunction = { _, data, nFingers, _, _ in
        guard let session = MouseEnhancerMiddleClickSession.activeSession else { return }
        session.threeDown = (nFingers == Int32(session.requiredFingerCount))
    }

    // MARK: - CGEvent Tap

    private func startEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        // `@convention(c)` closures cannot capture context, so `self` is passed through `userInfo`.
        let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let ptr = userInfo else { return Unmanaged.passUnretained(event) }
            let kCenter = Int64(CGMouseButton.center.rawValue)
            let passthrough = Unmanaged.passUnretained(event)
            let context = Unmanaged<CallbackContext>.fromOpaque(ptr).takeUnretainedValue()

            context.withOwner { session in
                if session.threeDown && (type == .leftMouseDown || type == .rightMouseDown) {
                    session.wasThreeDown = true
                    session.threeDown = false
                    event.type = .otherMouseDown
                    event.setIntegerValueField(.mouseEventButtonNumber, value: kCenter)
                } else if session.wasThreeDown && (type == .leftMouseUp || type == .rightMouseUp) {
                    session.wasThreeDown = false
                    event.type = .otherMouseUp
                    event.setIntegerValueField(.mouseEventButtonNumber, value: kCenter)
                }
            }

            return passthrough
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: callbackPointer
        ) else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("failed to create CGEvent tap; check Accessibility permission")
            return
        }

        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSrc = src
        eventTapCallbackPointer = callbackPointer
        logger.info("CGEvent tap started")
    }

    private func stopEventTap() {
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            eventTap = nil
            runLoopSrc = nil
            releaseCallbackPointer(&eventTapCallbackPointer)
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSrc = nil
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        releaseCallbackPointer(&eventTapCallbackPointer)
        logger.info("CGEvent tap stopped")
    }

    // MARK: - Multitouch Listeners

    private func startTouchListeners() {
        guard devices.isEmpty else { return }
        guard let multitouchRuntime else {
            logger.error("MultitouchSupport is unavailable; legacy middle click cannot start")
            return
        }
        devices = multitouchRuntime.createDeviceList()
        if devices.isEmpty {
            logger.warning("no multitouch devices detected; waiting for IOKit notification or wake retry")
        }
        devices.forEach {
            multitouchRuntime.register($0, callback: touchCallback)
            multitouchRuntime.start($0)
        }
    }

    private func stopTouchListeners() {
        devices.forEach {
            multitouchRuntime?.unregister($0, callback: touchCallback)
            multitouchRuntime?.stop($0)
            multitouchRuntime?.release($0)
        }
        devices.removeAll()
        threeDown = false
        wasThreeDown = false
    }

    // MARK: - Start / Stop

    func start() {
        startTouchListeners()
        startEventTap()
        observeSystemWake()
        observeMultitouchDeviceArrival()
        observeDisplayReconfiguration()
        logger.info("multitouch listener started deviceCount=\(self.devices.count, privacy: .public)")
    }

    func stop() {
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        stopEventTap()
        stopTouchListeners()
        logger.info("multitouch listener stopped")
    }

    func activate() {
        MouseEnhancerMiddleClickSession.activeSession?.stop()
        MouseEnhancerMiddleClickSession.activeSession = self
        start()
    }

    func deactivate() {
        if MouseEnhancerMiddleClickSession.activeSession === self {
            MouseEnhancerMiddleClickSession.activeSession = nil
        }
        stop()
    }

    // MARK: - System Recovery: Listener Restart

    /// Rebuilds fragile listeners (`CGEvent tap` and `MTDevice`) while keeping the session object.
    /// Used after wake, display reconfiguration, and trackpad re-enumeration.
    private func restartListeners() {
        logger.info("rebuilding multitouch and CGEvent tap listeners")
        stopEventTap()
        stopTouchListeners()
        startTouchListeners()
        startEventTap()
        logger.info("listener rebuild completed deviceCount=\(self.devices.count, privacy: .public)")
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        logger.info("scheduled listener restart reason=\(reason, privacy: .public) delay=\(delay, privacy: .public)")
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    // MARK: - NSWorkspace Wake Notification

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        let restartDelay = Self.wakeRestartDelay
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: restartDelay, reason: "systemWake")
            }
        }
    }

    private func removeSystemWakeObserver() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    // MARK: - IOKit Trackpad Device Arrival Notification

    /// Observes `AppleMultitouchDevice` first-match notifications. When the system re-enumerates
    /// trackpads after wake, external attach/detach, or driver reset, schedule a short-delay rebuild
    /// so the MTDevice list matches the actual hardware.
    private func observeMultitouchDeviceArrival() {
        guard ioNotificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("failed to create IONotificationPort; skipping device arrival observer")
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let context = CallbackContext(owner: self)
        let userInfo = Unmanaged.passRetained(context).toOpaque()
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                // The iterator must be drained or subsequent notifications will not fire.
                MouseEnhancerMiddleClickSession.drainIterator(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.scheduleRestart(after: 2, reason: "multitouchDeviceArrived")
                    }
                }
            },
            userInfo,
            &iterator
        )

        guard result == KERN_SUCCESS else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(userInfo).release()
            logger.error("IOServiceAddMatchingNotification failed result=\(result, privacy: .public)")
            IONotificationPortDestroy(port)
            return
        }

        // Initial registration must drain once to arm notifications.
        Self.drainIterator(iterator)

        ioNotificationPort = port
        ioIterator = iterator
        ioCallbackPointer = userInfo
    }

    private func removeMultitouchDeviceObserver() {
        callbackContext(from: ioCallbackPointer)?.invalidate()
        if ioIterator != 0 {
            IOObjectRelease(ioIterator)
            ioIterator = 0
        }
        if let port = ioNotificationPort {
            IONotificationPortDestroy(port)
            ioNotificationPort = nil
        }
        releaseCallbackPointer(&ioCallbackPointer)
    }

    private static func drainIterator(_ iterator: io_iterator_t) {
        while true {
            let next = IOIteratorNext(iterator)
            if next == 0 { break }
            IOObjectRelease(next)
        }
    }

    // MARK: - Display Reconfiguration Callback

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userData in
        let interesting: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(interesting).isEmpty else { return }
        guard let userData else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
        context.withOwner { session in
            DispatchQueue.main.async { [weak session] in
                session?.scheduleRestart(after: 2, reason: "displayReconfigured")
            }
        }
    }

    /// Observes display reconfiguration. Clamshell changes, external-display attach, and topology
    /// changes can invalidate the multitouch path. Match artginzburg/MiddleClick by restarting only
    /// for substantive changes such as setMode, add, remove, or disabled.
    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        let context = CallbackContext(owner: self)
        let userInfo = Unmanaged.passRetained(context).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, userInfo)
        if result == .success {
            displayCallbackRegistered = true
            displayCallbackPointer = userInfo
        } else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(userInfo).release()
            logger.error("CGDisplayRegisterReconfigurationCallback failed result=\(result.rawValue, privacy: .public)")
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        callbackContext(from: displayCallbackPointer)?.invalidate()
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, displayCallbackPointer)
        displayCallbackRegistered = false
        releaseCallbackPointer(&displayCallbackPointer)
    }

    private func callbackContext(
        from pointer: UnsafeMutableRawPointer?
    ) -> CallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    }

    private func releaseCallbackPointer(_ pointer: inout UnsafeMutableRawPointer?) {
        guard let retainedPointer = pointer else { return }
        callbackContext(from: retainedPointer)?.invalidate()
        Unmanaged<CallbackContext>.fromOpaque(retainedPointer).release()
        pointer = nil
    }
}
