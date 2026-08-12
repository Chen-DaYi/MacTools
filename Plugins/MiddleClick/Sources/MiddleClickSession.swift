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
protocol MiddleClickSessionManaging: AnyObject {
    var requiredFingerCount: Int { get set }

    func activate()
    func deactivate()
}

final class MiddleClickMultitouchRuntime: @unchecked Sendable {
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

    static func load() -> MiddleClickMultitouchRuntime? {
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
        return MiddleClickMultitouchRuntime(
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

private enum MiddleClickEventPoster {
    static func postClick() {
        guard let location = CGEvent(source: nil)?.location,
              let mouseDown = makeEvent(type: .otherMouseDown, location: location),
              let mouseUp = makeEvent(type: .otherMouseUp, location: location)
        else {
            return
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    private static func makeEvent(type: CGEventType, location: CGPoint) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        )
        event?.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.center.rawValue)
        )
        return event
    }
}

/// Manages raw trackpad contact frames and emits a middle-click for a completed multi-finger tap.
///
/// Behavior follows artginzburg/MiddleClick and the current TrackpadGestures recognizer:
/// - raw active contacts are filtered from MultitouchSupport frames;
/// - a tap is recognized only after all configured fingers release within time/movement limits;
/// - `otherMouseDown/Up` is synthesized at the current cursor location;
///
/// Recovery hooks match artginzburg/MiddleClick:
/// - `didWakeNotification`: after wake, the multitouch driver may not be ready; rebuild listeners
///   after a delay.
/// - `CGDisplayRegisterReconfigurationCallback`: also schedule a rebuild after display changes.
/// - IOKit `AppleMultitouchDevice` first-match notification: rebuild when built-in or external
///   trackpads are re-enumerated.
///
/// Mutable state is read and written both by multitouch C callback threads and by the
/// main thread, so the type is explicitly marked `@unchecked Sendable`. All lifecycle methods
/// (`start`, `stop`, `activate`, `deactivate`) and internal restart scheduling are expected to run
/// on the main thread.
final class MiddleClickSession: MiddleClickSessionManaging, @unchecked Sendable {
    private typealias CallbackContext = PluginCallbackContext<MiddleClickSession>

    // MARK: - Config (set on the main thread, read from callback threads)

    nonisolated(unsafe) var requiredFingerCount: Int = 3 {
        didSet {
            tapPipeline.updateFingerCount(requiredFingerCount)
        }
    }

    // MARK: - Infrastructure

    private var devices: [MTDevice] = []
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioIterator: io_iterator_t = 0
    private var ioCallbackPointer: UnsafeMutableRawPointer?
    private var displayCallbackRegistered = false
    private var displayCallbackPointer: UnsafeMutableRawPointer?
    private var restartWorkItem: DispatchWorkItem?
    private let multitouchRuntime: MiddleClickMultitouchRuntime?
    nonisolated private let tapPipeline = MiddleClickTapPipeline(fingerCount: 3)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "MiddleClickSession")

    /// After wake, the multitouch driver may not be ready; delay before rebuilding listeners.
    /// Keep this aligned with artginzburg/MiddleClick at 10 seconds: long sleep can make driver
    /// re-enumeration vary across hardware, and 2-3 second delays reproduced "MiddleClick stopped
    /// working" in testing. Users rarely need middle-click in the first few seconds after unlock.
    private static let wakeRestartDelay: TimeInterval = 10

    // MARK: - Singleton Reference (for C callback access)

    nonisolated(unsafe) static weak var activeSession: MiddleClickSession?

    init(multitouchRuntime: MiddleClickMultitouchRuntime? = .load()) {
        self.multitouchRuntime = multitouchRuntime
    }

    // MARK: - Multitouch Callback
    //
    // Converts private-framework frames into the same normalized contact snapshots used by the
    // current TrackpadGestures implementation. Stage values 3 and 4 are make-touch/touching;
    // hover, break-touch, and linger samples are not active fingers.

    private let touchCallback: MTFrameCallbackFunction = { device, data, nFingers, timestamp, _ in
        guard let session = MiddleClickSession.activeSession else { return }
        guard nFingers >= 0 else { return }

        let count = Int(nFingers)
        var contacts: [MiddleClickContactSnapshot] = []
        contacts.reserveCapacity(count)
        if count > 0, let data {
            for index in 0..<count {
                let touch = data[index]
                guard touch.stage.rawValue == 3 || touch.stage.rawValue == 4 else { continue }
                contacts.append(MiddleClickContactSnapshot(
                    identifier: Int(touch.identifier),
                    x: Double(touch.normalizedVector.position.x),
                    y: Double(touch.normalizedVector.position.y)
                ))
            }
        }

        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let frame = MiddleClickContactFrame(
            deviceID: UInt64(UInt(bitPattern: pointer)),
            timestamp: timestamp,
            contacts: contacts
        )
        if session.tapPipeline.process(frame) {
            MiddleClickEventPoster.postClick()
        }
    }

    // MARK: - Multitouch Listeners

    private func startTouchListeners() {
        guard devices.isEmpty else { return }
        guard let multitouchRuntime else {
            logger.error("MultitouchSupport is unavailable; middle click cannot start")
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
        tapPipeline.reset()
    }

    // MARK: - Start / Stop

    func start() {
        startTouchListeners()
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
        stopTouchListeners()
        logger.info("multitouch listener stopped")
    }

    func activate() {
        MiddleClickSession.activeSession?.stop()
        MiddleClickSession.activeSession = self
        start()
    }

    func deactivate() {
        if MiddleClickSession.activeSession === self {
            MiddleClickSession.activeSession = nil
        }
        stop()
    }

    // MARK: - System Recovery: Listener Restart

    /// Rebuilds fragile `MTDevice` listeners while keeping the session object.
    /// Used after wake, display reconfiguration, and trackpad re-enumeration.
    private func restartListeners() {
        logger.info("rebuilding multitouch listeners")
        stopTouchListeners()
        startTouchListeners()
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
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                // The iterator must be drained or subsequent notifications will not fire.
                MiddleClickSession.drainIterator(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.scheduleRestart(after: 2, reason: "multitouchDeviceArrived")
                    }
                }
            },
            callbackPointer,
            &iterator
        )

        guard result == KERN_SUCCESS else {
            logger.error("IOServiceAddMatchingNotification failed result=\(result, privacy: .public)")
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            IONotificationPortDestroy(port)
            return
        }

        // Initial registration must drain once to arm notifications.
        Self.drainIterator(iterator)

        ioNotificationPort = port
        ioIterator = iterator
        ioCallbackPointer = callbackPointer
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
        if let ioCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(ioCallbackPointer).release()
            self.ioCallbackPointer = nil
        }
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
        let context = Unmanaged<CallbackContext>
            .fromOpaque(userData)
            .takeUnretainedValue()
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
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            callbackPointer
        )
        if result == .success {
            displayCallbackRegistered = true
            displayCallbackPointer = callbackPointer
        } else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            logger.error("CGDisplayRegisterReconfigurationCallback failed result=\(result.rawValue, privacy: .public)")
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        callbackContext(from: displayCallbackPointer)?.invalidate()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayReconfigurationCallback,
            displayCallbackPointer
        )
        displayCallbackRegistered = false
        if let displayCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(displayCallbackPointer).release()
            self.displayCallbackPointer = nil
        }
    }

    private nonisolated func callbackContext(
        from pointer: UnsafeMutableRawPointer?
    ) -> CallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    }
}
