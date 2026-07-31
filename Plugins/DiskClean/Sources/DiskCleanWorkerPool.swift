import Darwin
import Foundation
import os

/// Exactly-once resume gate (design §3.4).
///
/// Timeout and worker completion **race both ways**: whoever arrives first resumes the
/// continuation; the loser only learns it lost — no resume, no touch of the other side's
/// memory (the worker keeps its own result and drops it on loss). This is the only safe way
/// to join the hard constraints "blocking syscalls cannot be cancelled" and
/// "a continuation may be resumed only once".
final class DiskCleanResumeGate<Value: Sendable>: Sendable {
    private let isResolvedLock = OSAllocatedUnfairLock(initialState: false)
    private let resumeHandler: @Sendable (Value) -> Void

    init(resume: @escaping @Sendable (Value) -> Void) {
        self.resumeHandler = resume
    }

    /// Claim resume rights. true = this call won the race and **must** call `deliver` exactly once afterward.
    ///
    /// Separated from `resolve` so the winner can finish its own bookkeeping **before** resume
    /// (the timeout side must record abandon budget and blacklist the device first); otherwise
    /// the waiter could observe the result before the state update.
    func claim() -> Bool {
        isResolvedLock.withLock { isResolved -> Bool in
            if isResolved { return false }
            isResolved = true
            return true
        }
    }

    /// Deliver the value and resume. May be called only once by the side whose `claim()` returned true.
    func deliver(_ value: Value) {
        resumeHandler(value)
    }

    /// true = this call won and already resumed; false = the other side won first and the caller must drop `value`.
    @discardableResult
    func resolve(with value: Value) -> Bool {
        guard claim() else { return false }
        deliver(value)
        return true
    }

    var isResolved: Bool {
        isResolvedLock.withLock { $0 }
    }
}

/// One blocking sizing job.
typealias DiskCleanSizingJob = @Sendable (DiskCleanSizingContext) -> DiskCleanSizeResult

/// Resident thread pool (design §3.4).
///
/// Why not GCD / Swift concurrency: task cancellation cannot interrupt blocking syscalls,
/// and GCD concurrent queues have no "abandon this thread and replace it" API. On a pathological
/// filesystem `getattrlistbulk` may never return, so we must abandon that thread together with
/// the stuck call — hence a self-owned `Thread` pool.
///
/// Abandon budget and circuit break are **process-wide**: the `shared` singleton accumulates
/// abandons across scans and fail-closes when exhausted — this process runs no more sizing
/// (Fast/Slow both stop), and later candidates become `partial([.unsupportedVolume])` and thus
/// uncleanable. No auto-recovery: retrying a pathological FS only burns more budget; nor do we
/// switch to the fallback sizer — it can block too and would break the leak ceiling.
final class DiskCleanWorkerPool: @unchecked Sendable {
    static let shared = DiskCleanWorkerPool()

    private let maxThreadCount: Int
    private let abandonBudget: Int
    private let timeoutQueue: DispatchQueue

    /// Protects all mutable state below and is used by worker threads waiting for work.
    private let condition = NSCondition()
    private var pendingItems: [WorkItem] = []
    private var liveThreadCount = 0
    private var idleThreadCount = 0
    private var abandonedThreadCount = 0
    private var circuitBroken = false
    private var blockedDevices: Set<UInt64> = []
    private var isShutDown = false

    init(
        maxThreadCount: Int = 3,
        abandonBudget: Int = 3,
        timeoutQueue: DispatchQueue = DispatchQueue(label: "com.mactools.diskclean.sizing-timeout")
    ) {
        self.maxThreadCount = max(maxThreadCount, 1)
        self.abandonBudget = max(abandonBudget, 1)
        self.timeoutQueue = timeoutQueue
    }

    /// Circuit-break state. The scan engine reports a `walkerCircuitBroken` limitation from this.
    var isCircuitBroken: Bool {
        condition.lock()
        defer { condition.unlock() }
        return circuitBroken
    }

    /// Cumulative abandoned-thread count. The scan engine reports a `threadsAbandoned` limitation from this.
    var abandonedThreads: Int {
        condition.lock()
        defer { condition.unlock() }
        return abandonedThreadCount
    }

    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult {
        await perform(deadline: deadline) { context in
            sizer.size(ofItemAt: path, context: context)
        }
    }

    func perform(deadline: Date, job: @escaping DiskCleanSizingJob) async -> DiskCleanSizeResult {
        if isCircuitBroken {
            return Self.circuitBrokenResult()
        }

        let cancellation = DiskCleanCancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DiskCleanSizeResult, Never>) in
                let gate = DiskCleanResumeGate<DiskCleanSizeResult> { result in
                    continuation.resume(returning: result)
                }
                submit(
                    WorkItem(gate: gate, job: job, deadline: deadline, cancellation: cancellation)
                )
            }
        } onCancel: {
            cancellation.set()
        }
    }

    /// Tests only: let resident threads exit so idle threads do not pile up in the test process.
    func shutDown() {
        condition.lock()
        isShutDown = true
        let drained = pendingItems
        pendingItems.removeAll()
        condition.broadcast()
        condition.unlock()
        for item in drained {
            item.cancelTimeout()
            item.gate.resolve(with: Self.circuitBrokenResult())
        }
    }

    // MARK: - Dispatch

    private func submit(_ item: WorkItem) {
        condition.lock()
        guard !circuitBroken, !isShutDown else {
            condition.unlock()
            item.gate.resolve(with: Self.circuitBrokenResult())
            return
        }
        pendingItems.append(item)
        let shouldStartThread = idleThreadCount == 0 && liveThreadCount < maxThreadCount
        if shouldStartThread {
            liveThreadCount += 1
        }
        condition.signal()
        condition.unlock()

        if shouldStartThread {
            startThread()
        }
        scheduleTimeout(for: item)
    }

    private func scheduleTimeout(for item: WorkItem) {
        let work = DispatchWorkItem { [weak self] in
            self?.handleTimeout(item)
        }
        item.attachTimeout(work)
        timeoutQueue.asyncAfter(
            deadline: .now() + max(0, item.deadline.timeIntervalSinceNow),
            execute: work
        )
    }

    private func startThread() {
        let worker = WorkerThread()
        let thread = Thread { [weak self] in
            self?.runWorkerLoop(worker)
        }
        thread.name = "com.mactools.diskclean.sizing"
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: - Worker threads

    private func runWorkerLoop(_ worker: WorkerThread) {
        while true {
            condition.lock()
            idleThreadCount += 1
            while pendingItems.isEmpty && !isShutDown && !worker.isAbandoned {
                condition.wait()
            }
            idleThreadCount -= 1

            if isShutDown || worker.isAbandoned {
                liveThreadCount -= 1
                condition.unlock()
                return
            }
            guard !pendingItems.isEmpty else {
                condition.unlock()
                continue
            }
            let item = pendingItems.removeFirst()
            // Circuit break may land between enqueue and pickup: fail closed.
            if circuitBroken {
                condition.unlock()
                item.cancelTimeout()
                item.gate.resolve(with: Self.circuitBrokenResult())
                continue
            }
            item.runningThread = worker
            condition.unlock()

            let result = item.job(makeContext(for: item))

            // Result is self-owned: if the timeout already claimed the gate, resolve returns false and the result is dropped.
            item.gate.resolve(with: result)
            item.cancelTimeout()

            condition.lock()
            item.runningThread = nil
            let wasAbandoned = worker.isAbandoned
            condition.unlock()

            // An abandoned thread exits after its stuck call finishes and does not take more work (liveThreadCount was already decremented on abandon).
            if wasAbandoned {
                return
            }
        }
    }

    private func makeContext(for item: WorkItem) -> DiskCleanSizingContext {
        DiskCleanSizingContext(
            deadline: item.deadline,
            isCancelled: { item.cancellation.isSet },
            admitDevice: { [weak self] device in
                self?.admit(device: device, for: item) ?? false
            },
            now: { Date() }
        )
    }

    private func admit(device: UInt64, for item: WorkItem) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        // Report the device id so a timeout abandon can blacklist a pathological device.
        item.reportedDevice = device
        return !circuitBroken && !blockedDevices.contains(device)
    }

    // MARK: - Timeout, abandon, and circuit break

    private func handleTimeout(_ item: WorkItem) {
        // Claim resume rights first: only a timeout that truly wins does abandon bookkeeping.
        // Bookkeeping must finish before deliver so the waiter never sees the result before circuit-break state.
        guard item.gate.claim() else { return }

        condition.lock()

        // Job still queued and not yet running → no stuck thread; dequeue only, no budget cost.
        if let index = pendingItems.firstIndex(where: { $0 === item }) {
            pendingItems.remove(at: index)
            condition.unlock()
            item.gate.deliver(Self.timedOutResult())
            return
        }

        guard let thread = item.runningThread else {
            condition.unlock()
            item.gate.deliver(Self.timedOutResult())
            return
        }

        // Thread is stuck in an uninterruptible syscall: abandon it and spawn a replacement.
        thread.markAbandoned()
        item.runningThread = nil
        liveThreadCount -= 1
        abandonedThreadCount += 1
        if let device = item.reportedDevice {
            blockedDevices.insert(device)
        }

        var drained: [WorkItem] = []
        if abandonedThreadCount >= abandonBudget {
            circuitBroken = true
            // Fail closed: even queued jobs stop running.
            drained = pendingItems
            pendingItems.removeAll()
        }
        let shouldStartThread = !circuitBroken
            && !pendingItems.isEmpty
            && idleThreadCount == 0
            && liveThreadCount < maxThreadCount
        if shouldStartThread {
            liveThreadCount += 1
        }
        condition.unlock()

        // State is settled; only now deliver the result.
        item.gate.deliver(Self.timedOutResult())

        for pending in drained {
            pending.cancelTimeout()
            pending.gate.resolve(with: Self.circuitBrokenResult())
        }
        if shouldStartThread {
            startThread()
        }
    }

    private static func timedOutResult() -> DiskCleanSizeResult {
        .unavailable(reasons: [.timedOut], observedAt: Date())
    }

    private static func circuitBrokenResult() -> DiskCleanSizeResult {
        .unavailable(reasons: [.unsupportedVolume], observedAt: Date())
    }

    // MARK: - Internal types

    /// Mutable fields are protected by `condition`.
    private final class WorkItem: @unchecked Sendable {
        let gate: DiskCleanResumeGate<DiskCleanSizeResult>
        let job: DiskCleanSizingJob
        let deadline: Date
        let cancellation: DiskCleanCancellationFlag

        var runningThread: WorkerThread?
        var reportedDevice: UInt64?
        /// `DispatchWorkItem` is not Sendable, so protect it with a separate NSLock instead of the pool condition.
        private let timeoutLock = NSLock()
        private var timeoutWork: DispatchWorkItem?

        init(
            gate: DiskCleanResumeGate<DiskCleanSizeResult>,
            job: @escaping DiskCleanSizingJob,
            deadline: Date,
            cancellation: DiskCleanCancellationFlag
        ) {
            self.gate = gate
            self.job = job
            self.deadline = deadline
            self.cancellation = cancellation
        }

        func attachTimeout(_ work: DispatchWorkItem) {
            timeoutLock.lock()
            timeoutWork = work
            timeoutLock.unlock()
        }

        func cancelTimeout() {
            timeoutLock.lock()
            let work = timeoutWork
            timeoutWork = nil
            timeoutLock.unlock()
            work?.cancel()
        }
    }

    private final class WorkerThread: @unchecked Sendable {
        /// Protected by `condition`.
        private(set) var isAbandoned = false

        func markAbandoned() {
            isAbandoned = true
        }
    }
}

/// Cancellation flag. `withTaskCancellationHandler` sets it on any thread; workers read it per batch.
final class DiskCleanCancellationFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    func set() {
        flag.withLock { $0 = true }
    }

    var isSet: Bool {
        flag.withLock { $0 }
    }
}
