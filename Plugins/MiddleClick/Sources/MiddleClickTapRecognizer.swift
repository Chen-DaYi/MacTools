import Foundation

struct MiddleClickContactSnapshot: Equatable, Sendable {
    let identifier: Int
    let x: Double
    let y: Double

    func distance(to other: MiddleClickContactSnapshot) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

struct MiddleClickContactFrame: Equatable, Sendable {
    let deviceID: UInt64
    let timestamp: TimeInterval
    let contacts: [MiddleClickContactSnapshot]

    var contactsByID: [Int: MiddleClickContactSnapshot] {
        Dictionary(contacts.map { ($0.identifier, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}

struct MiddleClickTapThresholds: Equatable, Sendable {
    var maximumMovement: Double = 0.05
    var minimumDuration: TimeInterval = 0.015
    var maximumDuration: TimeInterval = 0.30
    var acquisitionMaximumDuration: TimeInterval = 0.10

    static let `default` = MiddleClickTapThresholds()
}

/// Recognizes one complete multi-finger tap from raw MultitouchSupport contact frames.
///
/// Unlike a native mouse-event rewrite, recognition completes when every participating finger
/// leaves the trackpad. Finger identity, acquisition time, total duration, and movement are all
/// checked so a scroll or swipe does not become a middle click.
struct MiddleClickTapRecognizer: Sendable {
    private enum State: Sendable {
        case ready
        case acquiring(initial: [Int: MiddleClickContactSnapshot], startedAt: TimeInterval)
        case tracking(
            initial: [Int: MiddleClickContactSnapshot],
            startedAt: TimeInterval,
            isReleasing: Bool
        )
        case cancelled
    }

    let fingerCount: Int
    let thresholds: MiddleClickTapThresholds

    private var state: State = .ready

    init(
        fingerCount: Int,
        thresholds: MiddleClickTapThresholds = .default
    ) {
        self.fingerCount = fingerCount
        self.thresholds = thresholds
    }

    mutating func process(_ frame: MiddleClickContactFrame) -> Bool {
        let active = frame.contactsByID

        switch state {
        case .cancelled:
            if active.isEmpty {
                state = .ready
            }
            return false

        case .ready:
            guard !active.isEmpty else { return false }
            guard active.count <= fingerCount else {
                state = .cancelled
                return false
            }
            if active.count == fingerCount {
                state = .tracking(initial: active, startedAt: frame.timestamp, isReleasing: false)
            } else {
                state = .acquiring(initial: active, startedAt: frame.timestamp)
            }
            return false

        case let .acquiring(initial, startedAt):
            guard !active.isEmpty,
                  active.count <= fingerCount,
                  frame.timestamp - startedAt <= thresholds.acquisitionMaximumDuration,
                  initial.allSatisfy({ identifier, first in
                      guard let current = active[identifier] else { return false }
                      return current.distance(to: first) <= thresholds.maximumMovement
                  })
            else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            var accumulated = initial
            active.forEach { identifier, contact in
                if accumulated[identifier] == nil {
                    accumulated[identifier] = contact
                }
            }
            if accumulated.count == fingerCount {
                state = .tracking(
                    initial: accumulated,
                    startedAt: startedAt,
                    isReleasing: false
                )
            } else {
                state = .acquiring(initial: accumulated, startedAt: startedAt)
            }
            return false

        case let .tracking(initial, startedAt, wasReleasing):
            let duration = frame.timestamp - startedAt
            guard duration <= thresholds.maximumDuration,
                  active.keys.allSatisfy({ initial[$0] != nil }),
                  active.allSatisfy({ identifier, current in
                      guard let first = initial[identifier] else { return false }
                      return current.distance(to: first) <= thresholds.maximumMovement
                  })
            else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            if active.isEmpty {
                state = .ready
                return duration >= thresholds.minimumDuration
            }

            let isReleasing = wasReleasing || active.count < fingerCount
            // Once release starts, a finger returning is a new contact episode rather than the
            // continuation of the same tap.
            guard !(isReleasing && active.count == fingerCount) else {
                state = .cancelled
                return false
            }
            state = .tracking(initial: initial, startedAt: startedAt, isReleasing: isReleasing)
            return false
        }
    }

}

/// Serializes raw contact recognition across callbacks from multiple trackpads.
final class MiddleClickTapPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerCount: Int
    private var recognizersByDevice: [UInt64: MiddleClickTapRecognizer] = [:]

    init(fingerCount: Int) {
        self.fingerCount = fingerCount
    }

    func updateFingerCount(_ fingerCount: Int) {
        lock.withLock {
            guard self.fingerCount != fingerCount else { return }
            self.fingerCount = fingerCount
            clearState()
        }
    }

    /// Returns true when the frame completes a tap that still needs a synthesized middle click.
    func process(_ frame: MiddleClickContactFrame) -> Bool {
        lock.withLock {
            var recognizer = recognizersByDevice[frame.deviceID]
                ?? MiddleClickTapRecognizer(fingerCount: fingerCount)
            let recognized = recognizer.process(frame)
            if frame.contacts.isEmpty {
                recognizersByDevice[frame.deviceID] = nil
            } else {
                recognizersByDevice[frame.deviceID] = recognizer
            }
            return recognized
        }
    }

    func reset() {
        lock.withLock { clearState() }
    }

    private func clearState() {
        recognizersByDevice.removeAll()
    }
}
