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

@MainActor
protocol MouseEnhancerSessionManaging: AnyObject {
    var state: MouseEnhancerSessionState { get }

    @discardableResult
    func activate(configuration: MouseEnhancerConfiguration) -> Bool
    func update(configuration: MouseEnhancerConfiguration)
    func deactivate()
}

final class MouseEnhancerSession: MouseEnhancerSessionManaging, @unchecked Sendable {
    private enum Timing {
        static let wakeRestartDelay: TimeInterval = 2
    }

    private static let gestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
    private static weak var activeSession: MouseEnhancerSession?

    private let processor: MouseScrollEventProcessor

    private var scrollTap: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?
    private var gestureTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private var wakeObserver: (any NSObjectProtocol)?
    private var restartWorkItem: DispatchWorkItem?

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
        processor.configuration = configuration
        start()
        return scrollTap != nil
    }

    func update(configuration: MouseEnhancerConfiguration) {
        processor.configuration = configuration
    }

    func deactivate() {
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
            removeSystemWakeObserver()
            logger.error("scroll reverser session failed to start")
            return
        }

        observeSystemWake()
        logger.info(
            "scroll reverser session started scrollTap=\(self.scrollTap != nil, privacy: .public) gestureTap=\(self.gestureTap != nil, privacy: .public)"
        )
    }

    private func stop() {
        cancelPendingRestart()
        removeSystemWakeObserver()
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

    private func observeSystemWake() {
        guard wakeObserver == nil else {
            return
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(after: Timing.wakeRestartDelay)
            }
        }
    }

    private func removeSystemWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func scheduleRestart(after delay: TimeInterval) {
        cancelPendingRestart()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartWorkItem = nil
            self?.restartTaps()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingRestart() {
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
