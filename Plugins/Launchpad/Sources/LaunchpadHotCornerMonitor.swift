import AppKit

/// Polls the cursor position and fires `onTrigger` when it dwells in the configured
/// screen corner. Permission-free (reads `NSEvent.mouseLocation`, no event tap), and
/// fully stoppable — when the corner is `.off` no poll task runs at all.
///
/// Debounce: after firing, it re-arms only once the cursor *leaves* the corner, so
/// resting in the corner can't repeatedly re-summon the launcher.
@MainActor
final class LaunchpadHotCornerMonitor {
    var onTrigger: (() -> Void)?

    private var corner: LaunchpadPreferences.HotCorner = .off
    private var pollTask: Task<Void, Never>?
    private var dwellTicks = 0
    private var armed = true

    private let threshold: CGFloat = 4          // pt from the exact corner
    private let pollInterval = Duration.milliseconds(120)
    private let dwellTicksRequired = 2          // ~240ms in-corner before firing

    /// Idempotent: safe to call with an unchanged corner. That matters after a plugin
    /// pause/resume cycle — `deactivate` stops the poll while the preference keeps its value,
    /// so `activate` must be able to re-arm the SAME corner (an equality guard here once left
    /// the hot corner permanently dead after hide → re-show).
    func update(corner: LaunchpadPreferences.HotCorner) {
        self.corner = corner
        corner == .off ? stop() : start()
    }

    /// Whether the poll task is running. Exposed for tests.
    var isMonitoring: Bool { pollTask != nil }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        dwellTicks = 0
        armed = true
    }

    private func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(120))
            }
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let inCorner = NSScreen.screens.contains {
            Self.isInCorner(point, corner: corner, screenFrame: $0.frame, threshold: threshold)
        }
        guard inCorner else {
            dwellTicks = 0
            armed = true                        // re-arm once the cursor leaves
            return
        }
        guard armed else { return }             // already fired for this entry
        dwellTicks += 1
        if dwellTicks >= dwellTicksRequired {
            armed = false
            dwellTicks = 0
            onTrigger?()
        }
    }

    /// Pure corner hit-test (screen coords are bottom-left origin, y up).
    nonisolated static func isInCorner(
        _ point: CGPoint,
        corner: LaunchpadPreferences.HotCorner,
        screenFrame frame: CGRect,
        threshold: CGFloat
    ) -> Bool {
        guard corner != .off else { return false }
        let nearLeft = point.x >= frame.minX && point.x <= frame.minX + threshold
        let nearRight = point.x <= frame.maxX && point.x >= frame.maxX - threshold
        let nearBottom = point.y >= frame.minY && point.y <= frame.minY + threshold
        let nearTop = point.y <= frame.maxY && point.y >= frame.maxY - threshold
        switch corner {
        case .off: return false
        case .topLeft: return nearLeft && nearTop
        case .topRight: return nearRight && nearTop
        case .bottomLeft: return nearLeft && nearBottom
        case .bottomRight: return nearRight && nearBottom
        }
    }
}
