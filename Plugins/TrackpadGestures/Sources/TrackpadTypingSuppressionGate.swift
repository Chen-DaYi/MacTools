import CoreGraphics
import Foundation

final class TrackpadTypingSuppressionGate: @unchecked Sendable {
    static let defaultGracePeriod: TimeInterval = 0.4
    static let minimumGracePeriod: TimeInterval = 0.2
    static let maximumGracePeriod: TimeInterval = 1.0

    private let lock = NSLock()
    private var isEnabled = true
    private var gracePeriod = defaultGracePeriod
    private var activeKeyCodes = Set<CGKeyCode>()
    private var suppressedUntil: TimeInterval = -.infinity

    func update(isEnabled: Bool, gracePeriod: TimeInterval) {
        lock.withLock {
            self.isEnabled = isEnabled
            self.gracePeriod = Self.clamped(gracePeriod)
            if !isEnabled {
                activeKeyCodes.removeAll()
                suppressedUntil = -.infinity
            }
        }
    }

    func observeKeyDown(keyCode: CGKeyCode, at time: TimeInterval) {
        lock.withLock {
            guard isEnabled else { return }
            activeKeyCodes.insert(keyCode)
            suppressedUntil = max(suppressedUntil, time + gracePeriod)
        }
    }

    func observeKeyUp(keyCode: CGKeyCode, at time: TimeInterval) {
        lock.withLock {
            guard isEnabled else { return }
            activeKeyCodes.remove(keyCode)
            suppressedUntil = max(suppressedUntil, time + gracePeriod)
        }
    }

    func shouldSuppress(at time: TimeInterval) -> Bool {
        lock.withLock {
            isEnabled && (!activeKeyCodes.isEmpty || time < suppressedUntil)
        }
    }

    func reset() {
        lock.withLock {
            activeKeyCodes.removeAll()
            suppressedUntil = -.infinity
        }
    }

    static func clamped(_ gracePeriod: TimeInterval) -> TimeInterval {
        min(max(gracePeriod, minimumGracePeriod), maximumGracePeriod)
    }
}
