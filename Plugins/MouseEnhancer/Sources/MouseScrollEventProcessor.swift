import AppKit
import CoreGraphics
import Foundation

struct MouseScrollEventSnapshot: Equatable, Sendable {
    var isContinuous: Bool
    var scrollPhase: Int64
    var momentumPhase: Int64

    static let discreteWheel = MouseScrollEventSnapshot(
        isContinuous: false,
        scrollPhase: 0,
        momentumPhase: 0
    )

    static let phaseLessContinuousWheel = MouseScrollEventSnapshot(
        isContinuous: true,
        scrollPhase: 0,
        momentumPhase: 0
    )
}

struct MouseScrollDeltas: Equatable, Sendable {
    var deltaAxis1: Int64
    var deltaAxis2: Int64
    var pointDeltaAxis1: Int64
    var pointDeltaAxis2: Int64
    var fixedPointDeltaAxis1: Double
    var fixedPointDeltaAxis2: Double
}

struct MouseScrollProcessingResult: Equatable, Sendable {
    var source: MouseEnhancerDevice
    var shouldReverse: Bool
    var reverseHorizontal: Bool
    var reverseVertical: Bool
    var deltas: MouseScrollDeltas
}

final class MouseScrollEventProcessor: @unchecked Sendable {
    private enum Timing {
        static let touchRecentThreshold: UInt64 = 222_000_000
        static let touchStaleThreshold: UInt64 = 333_000_000
    }

    nonisolated(unsafe) var configuration: MouseEnhancerConfiguration
    nonisolated(unsafe) private var touchingCount = 0
    nonisolated(unsafe) private var lastTouchTime: UInt64 = 0
    nonisolated(unsafe) private var lastSource: MouseEnhancerDevice = .mouse
    nonisolated(unsafe) private var hasSeenGestureEvent = false
    nonisolated(unsafe) private var gestureMonitoringAvailable = false

    init(configuration: MouseEnhancerConfiguration) {
        self.configuration = configuration
    }

    func resetClassificationState() {
        touchingCount = 0
        lastTouchTime = 0
        lastSource = .mouse
        hasSeenGestureEvent = false
    }

    func recordGestureTouchingCount(_ count: Int, timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        hasSeenGestureEvent = true
        guard count >= 2 else {
            return
        }

        lastTouchTime = timestamp
        touchingCount = max(touchingCount, count)
    }

    func setGestureMonitoringAvailable(_ isAvailable: Bool) {
        gestureMonitoringAvailable = isAvailable
        if !isAvailable {
            resetClassificationState()
        }
    }

    func classify(
        snapshot: MouseScrollEventSnapshot,
        timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> MouseEnhancerDevice {
        let touching = touchingCount
        touchingCount = 0

        guard snapshot.isContinuous else {
            lastSource = .mouse
            return .mouse
        }

        let elapsed = lastTouchTime == 0 ? UInt64.max : timestamp &- lastTouchTime
        if touching >= 2, elapsed < Timing.touchRecentThreshold {
            lastSource = .trackpad
            return .trackpad
        }

        if snapshot.hasNoGesturePhase {
            lastSource = .mouse
            return .mouse
        }

        guard gestureMonitoringAvailable || hasSeenGestureEvent else {
            lastSource = .trackpad
            return .trackpad
        }

        if snapshot.isNormalScroll, elapsed > Timing.touchStaleThreshold {
            lastSource = .mouse
            return .mouse
        }

        return lastSource
    }

    func process(
        snapshot: MouseScrollEventSnapshot,
        deltas: MouseScrollDeltas,
        timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> MouseScrollProcessingResult {
        let source = classify(snapshot: snapshot, timestamp: timestamp)
        let shouldReverse = configuration.shouldReverse(device: source)
        guard shouldReverse else {
            return MouseScrollProcessingResult(
                source: source,
                shouldReverse: false,
                reverseHorizontal: false,
                reverseVertical: false,
                deltas: deltas
            )
        }

        let reverseHorizontal = configuration.shouldReverseHorizontal(device: source)
        let reverseVertical = configuration.shouldReverseVertical(device: source)
        return MouseScrollProcessingResult(
            source: source,
            shouldReverse: true,
            reverseHorizontal: reverseHorizontal,
            reverseVertical: reverseVertical,
            deltas: Self.reversed(
                deltas: deltas,
                reverseHorizontal: reverseHorizontal,
                reverseVertical: reverseVertical
            )
        )
    }

    @discardableResult
    func process(event: CGEvent) -> MouseScrollProcessingResult {
        let snapshot = MouseScrollEventSnapshot(event: event)
        let deltas = MouseScrollDeltas(event: event)
        let result = process(snapshot: snapshot, deltas: deltas)

        guard result.shouldReverse else {
            return result
        }

        event.applyScrollDeltas(
            result.deltas,
            reverseHorizontal: result.reverseHorizontal,
            reverseVertical: result.reverseVertical
        )
        return result
    }

    private static func reversed(
        deltas: MouseScrollDeltas,
        reverseHorizontal: Bool,
        reverseVertical: Bool
    ) -> MouseScrollDeltas {
        var next = deltas
        if reverseVertical {
            next.deltaAxis1 = -next.deltaAxis1
            next.pointDeltaAxis1 = -next.pointDeltaAxis1
            next.fixedPointDeltaAxis1 = -next.fixedPointDeltaAxis1
        }
        if reverseHorizontal {
            next.deltaAxis2 = -next.deltaAxis2
            next.pointDeltaAxis2 = -next.pointDeltaAxis2
            next.fixedPointDeltaAxis2 = -next.fixedPointDeltaAxis2
        }
        return next
    }
}

private extension MouseScrollEventSnapshot {
    init(event: CGEvent) {
        self.init(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
    }

    var hasNoGesturePhase: Bool {
        scrollPhase == 0 && momentumPhase == 0
    }

    var isNormalScroll: Bool {
        momentumPhase == 0
    }
}

private extension MouseScrollDeltas {
    init(event: CGEvent) {
        self.init(
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPointDeltaAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPointDeltaAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
    }
}

private extension CGEvent {
    func applyScrollDeltas(
        _ deltas: MouseScrollDeltas,
        reverseHorizontal: Bool,
        reverseVertical: Bool
    ) {
        // Set line deltas first. macOS may derive point/fixed deltas from them,
        // so point and fixed values are restored afterwards to preserve smooth scrolling.
        if reverseVertical {
            setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltas.deltaAxis1)
            setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltas.fixedPointDeltaAxis1)
            setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: deltas.pointDeltaAxis1)
        }

        if reverseHorizontal {
            setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltas.deltaAxis2)
            setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltas.fixedPointDeltaAxis2)
            setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: deltas.pointDeltaAxis2)
        }
    }
}
