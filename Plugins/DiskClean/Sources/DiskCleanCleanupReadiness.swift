import Foundation

/// Process-local gate: cleanup stays disabled until startup journal reconciliation finishes.
///
/// Without this, `activate` can launch reconciliation in parallel with a user-triggered clean.
/// Reconciliation and the executor must also share one journal instance; this gate covers the
/// "enable Clean only after reconcile" half of that contract.
final class DiskCleanCleanupReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var isReady = false

    /// Test seams may start ready when no journal recovery is needed.
    init(isReady: Bool = false) {
        self.isReady = isReady
    }

    var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady
    }

    func markReady() {
        lock.lock()
        isReady = true
        lock.unlock()
    }
}
