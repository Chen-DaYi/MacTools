import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
import MultitouchSupport
import OSLog

private struct SendableEventTapResult: @unchecked Sendable {
    let value: Unmanaged<CGEvent>?
}

@MainActor
protocol MultitouchFrameListening: AnyObject {
    var deviceCount: Int { get }
    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool
    func stop()
}

final class MultitouchFrameCallbackGate: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadContactFrame) -> Void

    private struct Registration {
        let deviceIDs: Set<UInt64>
        let startedAt: TimeInterval
        let handler: Handler
    }

    private let lock = NSLock()
    private var registration: Registration?

    func activate(
        deviceIDs: Set<UInt64>,
        startedAt: TimeInterval,
        handler: @escaping Handler
    ) {
        lock.withLock {
            registration = Registration(
                deviceIDs: deviceIDs,
                startedAt: startedAt,
                handler: handler
            )
        }
    }

    func invalidate() {
        lock.withLock {
            registration = nil
        }
    }

    @discardableResult
    func deliver(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard let registration,
                  registration.deviceIDs.contains(frame.deviceID),
                  frame.timestamp >= registration.startedAt
            else {
                return false
            }
            // Keep registration valid through delivery so stop() cannot release the device after
            // admission but before its frame reaches the session-level generation gate.
            registration.handler(frame)
            return true
        }
    }
}

final class MultitouchFrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    @discardableResult
    func deliver(
        generation expectedGeneration: UInt64,
        _ body: @Sendable () -> Void
    ) -> Bool {
        lock.withLock {
            guard generation == expectedGeneration else { return false }
            // Invalidation must wait through both snapshot mutation and recognition enqueue.
            body()
            return true
        }
    }

    func invalidate(_ body: () -> Void) {
        lock.withLock {
            generation &+= 1
            body()
        }
    }
}

final class TrackpadContactOccupancyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeDeviceIDs = Set<UInt64>()

    func observe(_ frame: TrackpadContactFrame) {
        lock.withLock {
            if frame.contacts.isEmpty {
                activeDeviceIDs.remove(frame.deviceID)
            } else {
                activeDeviceIDs.insert(frame.deviceID)
            }
        }
    }

    func snapshot() -> Set<UInt64> {
        lock.withLock { activeDeviceIDs }
    }

    func reset() {
        lock.withLock { activeDeviceIDs.removeAll() }
    }
}

final class MultitouchSupportRuntime: @unchecked Sendable {
    typealias CreateDeviceListFunction = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias RegisterCallbackFunction = @convention(c) (MTDevice, MTFrameCallbackFunction) -> Bool
    typealias UnregisterCallbackFunction = @convention(c) (MTDevice, MTFrameCallbackFunction) -> Bool
    typealias StartDeviceFunction = @convention(c) (MTDevice, Int32) -> Void
    typealias StopDeviceFunction = @convention(c) (MTDevice) -> Void
    typealias ReleaseDeviceFunction = @convention(c) (MTDevice) -> Void
    typealias IsDeviceRunningFunction = @convention(c) (MTDevice) -> Bool

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let libraryHandle: UnsafeMutableRawPointer
    private let createDeviceListFunction: CreateDeviceListFunction
    private let registerCallbackFunction: RegisterCallbackFunction
    private let unregisterCallbackFunction: UnregisterCallbackFunction
    private let startDeviceFunction: StartDeviceFunction
    private let stopDeviceFunction: StopDeviceFunction
    private let releaseDeviceFunction: ReleaseDeviceFunction
    private let isDeviceRunningFunction: IsDeviceRunningFunction

    static func load() -> MultitouchSupportRuntime? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            return nil
        }
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
            let releaseDevice: ReleaseDeviceFunction = loadSymbol("MTDeviceRelease", from: handle),
            let isDeviceRunning: IsDeviceRunningFunction = loadSymbol(
                "MTDeviceIsRunning", from: handle
            )
        else {
            dlclose(handle)
            return nil
        }
        return MultitouchSupportRuntime(
            libraryHandle: handle,
            createDeviceListFunction: createDeviceList,
            registerCallbackFunction: registerCallback,
            unregisterCallbackFunction: unregisterCallback,
            startDeviceFunction: startDevice,
            stopDeviceFunction: stopDevice,
            releaseDeviceFunction: releaseDevice,
            isDeviceRunningFunction: isDeviceRunning
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
        releaseDeviceFunction: ReleaseDeviceFunction,
        isDeviceRunningFunction: IsDeviceRunningFunction
    ) {
        self.libraryHandle = libraryHandle
        self.createDeviceListFunction = createDeviceListFunction
        self.registerCallbackFunction = registerCallbackFunction
        self.unregisterCallbackFunction = unregisterCallbackFunction
        self.startDeviceFunction = startDeviceFunction
        self.stopDeviceFunction = stopDeviceFunction
        self.releaseDeviceFunction = releaseDeviceFunction
        self.isDeviceRunningFunction = isDeviceRunningFunction
    }

    deinit {
        dlclose(libraryHandle)
    }

    func createDeviceList() -> [MTDevice] {
        createDeviceListFunction()?.takeUnretainedValue() as? [MTDevice] ?? []
    }

    func register(_ device: MTDevice, callback: MTFrameCallbackFunction) -> Bool {
        registerCallbackFunction(device, callback)
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

    func isRunning(_ device: MTDevice) -> Bool {
        isDeviceRunningFunction(device)
    }
}

@MainActor
final class MultitouchDeviceDriver: MultitouchFrameListening, @unchecked Sendable {
    private var devices: [MTDevice] = []
    private let runtime: MultitouchSupportRuntime?
    nonisolated private let callbackRegistry = MultitouchFrameCallbackGate()

    nonisolated private static let activeDriverLock = NSLock()
    nonisolated(unsafe) private static var activeDriver: MultitouchDeviceDriver?

    init(runtime: MultitouchSupportRuntime? = .load()) {
        self.runtime = runtime
    }

    private nonisolated static let touchCallback: MTFrameCallbackFunction = {
        device, touches, touchCount, timestamp, _ in
        guard let driver = currentActiveDriver(), let touches, touchCount >= 0
        else {
            return
        }

        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let deviceID = UInt64(UInt(bitPattern: pointer))
        let count = Int(touchCount)
        var contacts: [TrackpadContactSnapshot] = []
        contacts.reserveCapacity(count)
        for index in 0..<count {
            let touch = touches[index]
            // MTPathStage raw values 3 and 4 are make-touch and touching. Break/hover contacts
            // remain in the private callback briefly and must not be treated as active fingers.
            guard touch.stage.rawValue == 3 || touch.stage.rawValue == 4 else {
                continue
            }
            contacts.append(TrackpadContactSnapshot(
                identifier: Int(touch.identifier),
                x: Double(touch.normalizedVector.position.x),
                y: Double(touch.normalizedVector.position.y)
            ))
        }

        driver.callbackRegistry.deliver(TrackpadContactFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts
        ))
    }

    var deviceCount: Int { devices.count }

    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        guard let runtime else { return false }
        if let previous = Self.takeActiveDriver(), previous !== self {
            previous.stop()
        }
        stop()
        devices = runtime.createDeviceList()
        let deviceIDs = Set(devices.map(Self.deviceID))
        callbackRegistry.activate(
            deviceIDs: deviceIDs,
            // MTFrameCallbackFunction timestamps and systemUptime share the monotonic uptime base.
            // This rejects frames captured before this registration generation.
            startedAt: ProcessInfo.processInfo.systemUptime,
            handler: handler
        )
        Self.setActiveDriver(self)
        for device in devices {
            guard runtime.register(device, callback: Self.touchCallback) else {
                stop()
                return false
            }
            runtime.start(device)
            guard runtime.isRunning(device) else {
                stop()
                return false
            }
        }
        return true
    }

    func stop() {
        callbackRegistry.invalidate()
        Self.activeDriverLock.withLock {
            if Self.activeDriver === self {
                Self.activeDriver = nil
            }
        }
        devices.forEach { device in
            runtime?.unregister(device, callback: Self.touchCallback)
            runtime?.stop(device)
            runtime?.release(device)
        }
        devices.removeAll()
    }

    private nonisolated static func deviceID(_ device: MTDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private nonisolated static func currentActiveDriver() -> MultitouchDeviceDriver? {
        activeDriverLock.withLock { activeDriver }
    }

    private static func takeActiveDriver() -> MultitouchDeviceDriver? {
        activeDriverLock.withLock {
            defer { activeDriver = nil }
            return activeDriver
        }
    }

    private static func setActiveDriver(_ driver: MultitouchDeviceDriver) {
        activeDriverLock.withLock {
            activeDriver = driver
        }
    }
}

@MainActor
protocol MultitouchDeviceSessionManaging: AnyObject {
    var onRecognized: ((TrackpadGesture, UInt64) -> Void)? { get set }
    var onAvailabilityChange: ((Bool) -> Void)? { get set }
    var isActive: Bool { get }
    var deviceCount: Int { get }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool
    func update(gestures: Set<TrackpadGesture>)
    func updateNativeClickResolutions(_ resolutions: [TrackpadGesture: TrackpadNativeClickResolution])
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution?
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval)
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>)
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool
    func deactivate()
}

extension MultitouchDeviceSessionManaging {
    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {}
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? { nil }
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {}
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {}
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool { false }
}

@MainActor
final class MultitouchDeviceSession: MultitouchDeviceSessionManaging, @unchecked Sendable {
    var onRecognized: ((TrackpadGesture, UInt64) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?

    private(set) var isActive = false
    var deviceCount: Int { driver.deviceCount }

    private let driver: any MultitouchFrameListening
    nonisolated private let middleClickCandidateTimeline: TrackpadMiddleClickCandidateTimeline
    private let middleClickCoordinator: TrackpadMiddleClickCoordinator
    private var nativeClickResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = [:]
    nonisolated private let typingSuppressionGate = TrackpadTypingSuppressionGate()
    nonisolated private let recognitionGeneration = TrackpadGestureRecognitionGeneration()
    nonisolated private let frameDeliveryGate = MultitouchFrameDeliveryGate()
    nonisolated private let contactOccupancyTracker = TrackpadContactOccupancyTracker()
    nonisolated private let frameIngestionClock: @Sendable () -> TimeInterval
    nonisolated private let recognitionBeforeFrameProcessing: (@Sendable () -> Void)?
    private lazy var recognitionWorker = TrackpadGestureRecognitionWorker(
        generation: recognitionGeneration,
        beforeFrameProcessing: recognitionBeforeFrameProcessing
    ) { [weak self] gesture, deviceID, generation in
        Task { @MainActor [weak self] in
            guard let self,
                  self.isActive,
                  self.recognitionGeneration.isCurrent(generation)
            else {
                return
            }
            self.onRecognized?(gesture, deviceID)
        }
    }

    private var configuredGestures = Set<TrackpadGesture>()
    private var isActivationRequested = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioArrivalIterator: io_iterator_t = 0
    private var ioTerminationIterator: io_iterator_t = 0
    private var displayCallbackRegistered = false
    private var restartWorkItem: DispatchWorkItem?
    private let testEventTapStart: (@MainActor () -> Bool)?
    private let testEventTapStop: (@MainActor () -> Void)?
    private let deviceChangeRestartDelay: TimeInterval

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MultitouchDeviceSession"
    )

    private static let wakeRestartDelay: TimeInterval = 10
    private static let recoveryRetryDelay: TimeInterval = 2

    init(
        driver: (any MultitouchFrameListening)? = nil,
        testEventTapStart: (@MainActor () -> Bool)? = nil,
        testEventTapStop: (@MainActor () -> Void)? = nil,
        deviceChangeRestartDelay: TimeInterval = 2,
        recognitionBeforeFrameProcessing: (@Sendable () -> Void)? = nil,
        middleClickClock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        synthesizeMiddleClick: @escaping @Sendable @MainActor () -> Void = {
            TrackpadGestureActionExecutor().execute(.middleClick)
        },
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void = {
            TrackpadMiddleClickEventPoster.postButtonUp(
                eventSourceMarker: TrackpadMiddleClickCoordinator.replayMarker
            )
        },
        postMiddleClickEvent: @escaping @Sendable @MainActor (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        middleClickEventOrigin: @escaping @Sendable @MainActor (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin = { _ in
            .unknown
        }
    ) {
        let candidateTimeline = TrackpadMiddleClickCandidateTimeline()
        self.driver = driver ?? MultitouchDeviceDriver()
        middleClickCandidateTimeline = candidateTimeline
        frameIngestionClock = middleClickClock
        self.recognitionBeforeFrameProcessing = recognitionBeforeFrameProcessing
        middleClickCoordinator = TrackpadMiddleClickCoordinator(
            clock: middleClickClock,
            synthesizeMiddleClick: synthesizeMiddleClick,
            releaseMiddleButton: releaseMiddleButton,
            postEvent: postMiddleClickEvent,
            candidateTimeline: candidateTimeline,
            eventOrigin: middleClickEventOrigin
        )
        self.testEventTapStart = testEventTapStart
        self.testEventTapStop = testEventTapStop
        self.deviceChangeRestartDelay = deviceChangeRestartDelay
    }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        configuredGestures = gestures
        isActivationRequested = true
        recognitionWorker.configure(gestures: gestures, reset: true)
        observeSystemWake()
        observeMultitouchDeviceChanges()
        observeDisplayReconfiguration()

        if isActive {
            return true
        }
        guard startEventTap() else {
            logger.error("failed to create event-tap lifecycle monitor")
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "initialRetry")
            return false
        }

        guard startDriver() else {
            logger.error("failed to register or start multitouch contact callbacks")
            stopEventTap()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return false
        }
        cancelPendingRestart()
        isActive = true
        onAvailabilityChange?(true)
        logger.info("multitouch session started deviceCount=\(self.driver.deviceCount, privacy: .public)")
        return true
    }

    func update(gestures: Set<TrackpadGesture>) {
        configuredGestures = gestures
        recognitionWorker.configure(gestures: gestures)
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        updateNativeClickResolutions(
            Dictionary(uniqueKeysWithValues: gestures.map { ($0, .middleClick) })
        )
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolveNativeClick(for: gesture, deviceID: deviceID) == .middleClick
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        nativeClickResolutions = resolutions
        middleClickCoordinator.updateClickResolutions(resolutions)
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? {
        guard let resolution = nativeClickResolutions[gesture] else { return nil }
        middleClickCoordinator.recognize(deviceID: deviceID, resolution: resolution)
        return resolution
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingSuppressionGate.update(isEnabled: isEnabled, gracePeriod: gracePeriod)
    }

    func deactivate() {
        isActivationRequested = false
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        invalidateDriverCallbacks()
        driver.stop()
        stopEventTap()
        middleClickCoordinator.reset()
        typingSuppressionGate.reset()
        recognitionWorker.configure(gestures: [], reset: true)
        isActive = false
        logger.info("multitouch session stopped")
    }

    private func startEventTap() -> Bool {
        if let testEventTapStart {
            return testEventTapStart()
        }
        if let eventTap, CFMachPortIsValid(eventTap) {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let session = Unmanaged<MultitouchDeviceSession>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in
                    session.middleClickCoordinator.reset()
                    session.typingSuppressionGate.reset()
                    session.reenableEventTap()
                }
                return Unmanaged.passUnretained(event)
            }

            return MainActor.assumeIsolated {
                SendableEventTapResult(value: session.handleEventTapEvent(type: type, event: event))
            }.value
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func reenableEventTap() {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        middleClickCoordinator.reset()
        typingSuppressionGate.reset()
        if let testEventTapStop {
            testEventTapStop()
            return
        }
        guard let eventTap else {
            eventTapSource = nil
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        eventTapSource = nil
    }

    private func restartListeners(reason: String) {
        guard isActivationRequested else {
            return
        }
        cancelPendingRestart()
        logger.info("restarting listeners reason=\(reason, privacy: .public)")
        isActive = false
        invalidateDriverCallbacks()
        driver.stop()
        stopEventTap()
        recognitionWorker.configure(gestures: configuredGestures, reset: true)
        guard startEventTap() else {
            logger.error("event tap could not be restored")
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "eventTapRetry")
            return
        }
        guard startDriver() else {
            logger.error("multitouch contact callbacks could not be restored")
            stopEventTap()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return
        }
        isActive = true
        onAvailabilityChange?(true)
    }

    private func startDriver() -> Bool {
        let callbackGeneration = frameDeliveryGate.beginGeneration()
        let frameDeliveryGate = frameDeliveryGate
        let candidateTimeline = middleClickCandidateTimeline
        let typingSuppressionGate = typingSuppressionGate
        let contactOccupancyTracker = contactOccupancyTracker
        let frameIngestionClock = frameIngestionClock
        let recognitionWorker = recognitionWorker
        let started = driver.start(handler: {
            [
                frameDeliveryGate,
                candidateTimeline,
                typingSuppressionGate,
                contactOccupancyTracker,
                frameIngestionClock,
                recognitionWorker,
            ] frame in
            frameDeliveryGate.deliver(generation: callbackGeneration) {
                contactOccupancyTracker.observe(frame)
                let now = frameIngestionClock()
                let suppressRecognition = typingSuppressionGate.shouldSuppress(at: now)
                if suppressRecognition {
                    candidateTimeline.reset()
                } else {
                    candidateTimeline.observe(frame: frame, at: now)
                }
                recognitionWorker.process(frame, suppressRecognition: suppressRecognition)
            }
        })
        if !started {
            invalidateDriverCallbacks()
        }
        return started
    }

    private func invalidateDriverCallbacks() {
        frameDeliveryGate.invalidate {
            middleClickCandidateTimeline.reset()
            contactOccupancyTracker.reset()
        }
    }

    private func handleEventTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .keyUp {
            if event.getIntegerValueField(.eventSourceUserData)
                == TrackpadGestureActionExecutor.keyboardEventMarker {
                return Unmanaged.passUnretained(event)
            }

            let now = frameIngestionClock()
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                typingSuppressionGate.observeKeyDown(keyCode: keyCode, at: now)
            } else {
                typingSuppressionGate.observeKeyUp(keyCode: keyCode, at: now)
            }
            if typingSuppressionGate.shouldSuppress(at: now) {
                recognitionWorker.beginSuppression(
                    activeDeviceIDs: contactOccupancyTracker.snapshot()
                )
                middleClickCoordinator.reset()
            }
            return Unmanaged.passUnretained(event)
        }
        return middleClickCoordinator.handleNativeEvent(type: type, event: event)
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners(reason: reason)
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: Self.wakeRestartDelay, reason: "systemWake")
            }
        }
    }

    private func removeSystemWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func observeMultitouchDeviceChanges() {
        guard ioNotificationPort == nil,
              let port = IONotificationPortCreate(kIOMainPortDefault)
        else {
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        var arrivalIterator: io_iterator_t = 0
        let arrivalResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let session = Unmanaged<MultitouchDeviceSession>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    session.handleMultitouchDeviceChange(reason: "deviceArrived")
                }
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &arrivalIterator
        )

        guard arrivalResult == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }

        var terminationIterator: io_iterator_t = 0
        let terminationResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let session = Unmanaged<MultitouchDeviceSession>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    session.handleMultitouchDeviceChange(reason: "deviceRemoved")
                }
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &terminationIterator
        )

        guard terminationResult == KERN_SUCCESS else {
            IOObjectRelease(arrivalIterator)
            IONotificationPortDestroy(port)
            return
        }

        Self.drain(arrivalIterator)
        Self.drain(terminationIterator)
        ioNotificationPort = port
        ioArrivalIterator = arrivalIterator
        ioTerminationIterator = terminationIterator
    }

    private func removeMultitouchDeviceObserver() {
        if ioArrivalIterator != 0 {
            IOObjectRelease(ioArrivalIterator)
            ioArrivalIterator = 0
        }
        if ioTerminationIterator != 0 {
            IOObjectRelease(ioTerminationIterator)
            ioTerminationIterator = 0
        }
        if let ioNotificationPort {
            IONotificationPortDestroy(ioNotificationPort)
            self.ioNotificationPort = nil
        }
    }

    private func handleMultitouchDeviceChange(reason: String) {
        scheduleRestart(after: deviceChangeRestartDelay, reason: reason)
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            IOObjectRelease(service)
        }
    }

    private nonisolated static let displayCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userInfo in
        let relevant: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(relevant).isEmpty, let userInfo else {
            return
        }
        let session = Unmanaged<MultitouchDeviceSession>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            session.scheduleRestart(after: 2, reason: "displayReconfigured")
        }
    }

    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        if CGDisplayRegisterReconfigurationCallback(
            Self.displayCallback,
            Unmanaged.passUnretained(self).toOpaque()
        ) == .success {
            displayCallbackRegistered = true
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(
            Self.displayCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayCallbackRegistered = false
    }

    #if DEBUG
    func restartImmediatelyForTests() {
        restartListeners(reason: "test")
    }

    func simulateWakeRecoveryForTests() {
        restartListeners(reason: "systemWakeTest")
    }

    func simulateDeviceRecoveryForTests() {
        restartListeners(reason: "deviceReenumeratedTest")
    }

    func simulateDeviceRemovalNotificationForTests() {
        handleMultitouchDeviceChange(reason: "deviceRemovedTest")
    }

    func handleNativeEventForTests(type: CGEventType, event: CGEvent) -> Bool {
        handleEventTapEvent(type: type, event: event) == nil
    }

    func simulateEventTapDisableForTests() {
        middleClickCoordinator.reset()
    }

    func waitForRecognitionForTests() {
        recognitionWorker.waitUntilIdleForTests()
    }
    #endif
}
