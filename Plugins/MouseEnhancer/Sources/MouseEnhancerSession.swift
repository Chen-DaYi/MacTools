import AppKit
import CoreGraphics
import Foundation
import OSLog

struct MouseEnhancerSessionState: Equatable, Sendable {
    var scrollTapInstalled: Bool
    var gestureTapInstalled: Bool

    static let inactive = MouseEnhancerSessionState(
        scrollTapInstalled: false,
        gestureTapInstalled: false
    )
}

enum MouseEnhancerRecoveryCause: Equatable, Sendable {
    case applicationActivity
    case displayTopology

    var delay: TimeInterval {
        switch self {
        case .applicationActivity:
            // The host already holds `.waking` for two seconds after a full system wake. A short
            // final delay also covers lock-only and display-only wake transitions.
            return 0.25
        case .displayTopology:
            // Physical display changes can briefly re-enumerate the multitouch path.
            return 2
        }
    }

    var logName: String {
        switch self {
        case .applicationActivity:
            return "applicationActivityChanged"
        case .displayTopology:
            return "displayTopologyChanged"
        }
    }
}

struct MouseEnhancerRecoveryState: Equatable, Sendable {
    private(set) var isInputAvailable = true
    private(set) var pendingCause: MouseEnhancerRecoveryCause?

    mutating func setInputAvailable(_ isAvailable: Bool) {
        isInputAvailable = isAvailable
    }

    mutating func request(_ cause: MouseEnhancerRecoveryCause) {
        guard let pendingCause else {
            self.pendingCause = cause
            return
        }

        if cause.delay >= pendingCause.delay {
            self.pendingCause = cause
        }
    }

    mutating func clearPending() {
        pendingCause = nil
    }
}

@MainActor
protocol MouseEnhancerSessionManaging: AnyObject {
    var state: MouseEnhancerSessionState { get }

    @discardableResult
    func activate(configuration: MouseEnhancerConfiguration) -> Bool
    func update(configuration: MouseEnhancerConfiguration)
    func inputActivityDidBecomeUnavailable()
    func inputActivityDidBecomeAvailable()
    func displayTopologyDidChange()
    func deactivate()
}

final class MouseEnhancerSession: MouseEnhancerSessionManaging, @unchecked Sendable {
    private static let gestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
    private static weak var activeSession: MouseEnhancerSession?

    private let processor: MouseScrollEventProcessor

    private var scrollTap: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?
    private var gestureTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private var restartWorkItem: DispatchWorkItem?
    private var restartGeneration = 0
    private var recoveryState = MouseEnhancerRecoveryState()
    private var isActivated = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MouseEnhancerSession"
    )

    var state: MouseEnhancerSessionState {
        MouseEnhancerSessionState(
            scrollTapInstalled: scrollTap != nil,
            gestureTapInstalled: gestureTap != nil
        )
    }

    init(configuration: MouseEnhancerConfiguration = .default) {
        self.processor = MouseScrollEventProcessor(configuration: configuration)
    }

    @discardableResult
    func activate(configuration: MouseEnhancerConfiguration) -> Bool {
        Self.activeSession?.deactivate()
        Self.activeSession = self
        isActivated = true
        processor.configuration = configuration
        start()
        if scrollTap == nil {
            isActivated = false
            recoveryState.clearPending()
            if Self.activeSession === self {
                Self.activeSession = nil
            }
        } else if recoveryState.isInputAvailable {
            // The taps were created after the latest interruption, so no older recovery request
            // needs to rebuild them again.
            recoveryState.clearPending()
        } else {
            requestRecovery(.applicationActivity)
        }
        return scrollTap != nil
    }

    func update(configuration: MouseEnhancerConfiguration) {
        processor.configuration = configuration
    }

    func deactivate() {
        isActivated = false
        recoveryState.clearPending()
        if Self.activeSession === self {
            Self.activeSession = nil
        }
        stop()
    }

    private func start() {
        guard scrollTap == nil else {
            return
        }

        processor.resetClassificationState()
        startGestureTap()
        startScrollTap()
        guard scrollTap != nil else {
            stopGestureTap()
            logger.error("scroll reverser session failed to start")
            return
        }

        logger.info(
            "scroll reverser session started scrollTap=\(self.scrollTap != nil, privacy: .public) gestureTap=\(self.gestureTap != nil, privacy: .public)"
        )
    }

    private func stop() {
        cancelPendingRestart()
        stopScrollTap()
        stopGestureTap()
        logger.info("scroll reverser session stopped")
    }

    private func startScrollTap() {
        let mask = CGEventMask(1) << UInt64(CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("failed to create scroll CGEvent tap; check Accessibility permission")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.error("failed to create scroll CGEvent run loop source")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        scrollTap = tap
        scrollRunLoopSource = source
    }

    private func stopScrollTap() {
        if let scrollTap {
            CGEvent.tapEnable(tap: scrollTap, enable: false)
        }

        if let scrollRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), scrollRunLoopSource, .commonModes)
        }

        if let scrollTap {
            CFMachPortInvalidate(scrollTap)
        }

        scrollRunLoopSource = nil
        scrollTap = nil
    }

    private func startGestureTap() {
        let mask = CGEventMask(1) << UInt64(Self.gestureEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.warning("failed to create gesture CGEvent tap; Input Monitoring may be missing")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            logger.warning("failed to create gesture CGEvent run loop source")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        gestureTap = tap
        gestureRunLoopSource = source
        processor.setGestureMonitoringAvailable(true)
    }

    private func stopGestureTap() {
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
        }

        if let gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
        }

        if let gestureTap {
            CFMachPortInvalidate(gestureTap)
        }

        gestureRunLoopSource = nil
        gestureTap = nil
        processor.setGestureMonitoringAvailable(false)
    }

    private func restartTaps() {
        stopScrollTap()
        stopGestureTap()
        processor.resetClassificationState()
        startGestureTap()
        startScrollTap()
        guard scrollTap != nil else {
            stopGestureTap()
            logger.error("scroll reverser session failed to restart")
            return
        }
    }

    private func enableTapsIfNeeded() {
        if let scrollTap, !CGEvent.tapIsEnabled(tap: scrollTap) {
            CGEvent.tapEnable(tap: scrollTap, enable: true)
        }
        if let gestureTap, !CGEvent.tapIsEnabled(tap: gestureTap) {
            CGEvent.tapEnable(tap: gestureTap, enable: true)
        }
    }

    func inputActivityDidBecomeUnavailable() {
        recoveryState.setInputAvailable(false)
        cancelPendingRestart()
        processor.resetClassificationState()
        recoveryState.request(.applicationActivity)
    }

    func inputActivityDidBecomeAvailable() {
        recoveryState.setInputAvailable(true)
        requestRecovery(.applicationActivity)
    }

    func displayTopologyDidChange() {
        guard isActivated else { return }
        requestRecovery(.displayTopology)
    }

    private func requestRecovery(_ cause: MouseEnhancerRecoveryCause) {
        // Reset immediately so scrolling during the short driver-settle window cannot inherit a
        // stale mouse classification. The taps themselves are rebuilt after the debounce delay.
        processor.resetClassificationState()
        recoveryState.request(cause)
        cancelPendingRestart()

        guard isActivated,
              recoveryState.isInputAvailable,
              let pendingCause = recoveryState.pendingCause else { return }
        logger.info(
            "scheduled scroll tap restart reason=\(pendingCause.logName, privacy: .public) delay=\(pendingCause.delay, privacy: .public)"
        )
        let generation = restartGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.restartGeneration == generation,
                  self.isActivated,
                  self.recoveryState.isInputAvailable else { return }
            self.restartWorkItem = nil
            self.recoveryState.clearPending()
            self.restartTaps()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + pendingCause.delay,
            execute: workItem
        )
    }

    private func cancelPendingRestart() {
        restartGeneration &+= 1
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let session = Unmanaged<MouseEnhancerSession>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            session.enableTapsIfNeeded()
            return Unmanaged.passUnretained(event)
        }

        if type == MouseEnhancerSession.gestureEventType {
            let touching = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil).count ?? 0
            session.processor.recordGestureTouchingCount(touching)
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            session.processor.process(event: event)
        }

        return Unmanaged.passUnretained(event)
    }
}
