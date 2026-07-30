import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanWorkerPoolTests: XCTestCase {
    /// All pools under test are registered here and torn down together so idle threads do not pile up.
    private var pools: [DiskCleanWorkerPool] = []
    /// Releases deliberately stuck jobs; teardown must signal all of them or threads stay forever.
    private var releaseSemaphores: [DispatchSemaphore] = []

    override func tearDown() {
        for semaphore in releaseSemaphores {
            // Extra signals are harmless; ensure stuck jobs can finish and exit.
            semaphore.signal()
            semaphore.signal()
        }
        releaseSemaphores.removeAll()
        for pool in pools {
            pool.shutDown()
        }
        pools.removeAll()
        super.tearDown()
    }

    // MARK: - Exactly-once gate: two-way race

    /// Timeout and job completion race both ways: no matter how many concurrent callers, `resolve` has one winner
    /// and resume happens once. Multiple rounds raise the chance of hitting the race.
    func testResumeGateResumesExactlyOnceUnderConcurrentRace() {
        for round in 0..<200 {
            let resumeCount = AtomicCounter()
            let winnerCount = AtomicCounter()
            let gate = DiskCleanResumeGate<Int> { _ in resumeCount.increment() }

            let contenderCount = 8
            let startGate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for contender in 0..<contenderCount {
                DispatchQueue.global().async(group: group) {
                    startGate.wait()
                    if gate.resolve(with: contender) {
                        winnerCount.increment()
                    }
                }
            }
            for _ in 0..<contenderCount {
                startGate.signal()
            }
            group.wait()

            XCTAssertEqual(winnerCount.value, 1, "round \(round) must have exactly one winner")
            XCTAssertEqual(resumeCount.value, 1, "round \(round) resume must happen only once")
            XCTAssertTrue(gate.isResolved)
        }
    }

    /// The race loser must neither resume nor rewrite the decided result.
    func testLosingContenderDoesNotResume() {
        let delivered = AtomicBox<Int>()
        let gate = DiskCleanResumeGate<Int> { delivered.value = $0 }

        XCTAssertTrue(gate.resolve(with: 1))
        XCTAssertFalse(gate.resolve(with: 2))
        XCTAssertFalse(gate.claim())
        XCTAssertEqual(delivered.value, 1)
    }

    // MARK: - Happy path

    func testReturnsJobResult() async {
        let pool = makePool()

        let result = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in
            DiskCleanSizeResult(
                estimatedBytes: 4321,
                fileCount: 7,
                completeness: .complete,
                rootIdentity: nil,
                observedAt: Date()
            )
        }

        XCTAssertEqual(result.estimatedBytes, 4321)
        XCTAssertEqual(result.fileCount, 7)
        XCTAssertEqual(result.completeness, .complete)
    }

    func testRunsManyJobsWithoutExceedingThreadBudget() async {
        let pool = makePool(maxThreadCount: 3)
        let concurrency = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = await pool.perform(deadline: Date().addingTimeInterval(10)) { _ in
                        concurrency.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        concurrency.leave()
                        return Self.completeResult
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(concurrency.peak, 3, "resident thread cap is 3; concurrency must not exceed it")
        XCTAssertEqual(concurrency.totalRuns, 12)
    }

    func testSizeConvenienceForwardsContextToSizer() async {
        let pool = makePool()
        let sizer = RecordingSizer()
        let deadline = Date().addingTimeInterval(3)

        let result = await pool.size(ofItemAt: "/some/path", using: sizer, deadline: deadline)

        XCTAssertEqual(sizer.observedPath, "/some/path")
        XCTAssertEqual(sizer.observedDeadline, deadline)
        XCTAssertEqual(result.completeness, .complete)
    }

    // MARK: - Timeout, abandon, and device blacklist

    /// Job stuck in an uninterruptible call → timeout wins, thread is abandoned, its device is blacklisted.
    func testTimeoutAbandonsThreadAndBlocklistsReportedDevice() async {
        let pool = makePool(maxThreadCount: 3, abandonBudget: 3)
        let hanging = makeHangingJob(reportingDevice: 42)

        let result = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: hanging.job)

        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]))
        XCTAssertEqual(pool.abandonedThreads, 1, "stuck thread must count against abandon budget")
        XCTAssertFalse(pool.isCircuitBroken, "budget 3 with 1 used must not circuit-break yet")

        // Blacklist hit: later jobs reporting the same device are refused and must abandon immediately.
        let admitted = AtomicBox<Bool>()
        _ = await pool.perform(deadline: Date().addingTimeInterval(5)) { context in
            admitted.value = context.admitDevice(42)
            return Self.completeResult
        }
        XCTAssertEqual(admitted.value, false, "device of an abandoned thread must be blacklisted")

        // Other devices are unaffected.
        let otherAdmitted = AtomicBox<Bool>()
        _ = await pool.perform(deadline: Date().addingTimeInterval(5)) { context in
            otherAdmitted.value = context.admitDevice(7)
            return Self.completeResult
        }
        XCTAssertEqual(otherAdmitted.value, true, "healthy devices must not be collateralized")
    }

    /// When a stuck job finally returns, its result must be dropped in place (gate already taken by timeout)
    /// and must never resume the continuation twice (that would crash).
    func testLateJobResultIsDiscardedWithoutDoubleResume() async {
        let pool = makePool(maxThreadCount: 3, abandonBudget: 3)
        let hanging = makeHangingJob()

        let result = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: hanging.job)
        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]))

        // Release the stuck job so it finishes the "own and discard result" path.
        hanging.release.signal()
        let finished = await waitUntil { hanging.didFinish.value == true }
        XCTAssertTrue(finished, "stuck job should finish and exit on its own")

        // Pool remains usable (abandoned threads are replaced).
        let next = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in Self.completeResult }
        XCTAssertEqual(next.completeness, .complete)
    }

    /// Jobs that time out while still queued stuck no thread → must not consume abandon budget.
    func testTimeoutOfQueuedJobDoesNotConsumeAbandonBudget() async {
        let pool = makePool(maxThreadCount: 1, abandonBudget: 3)
        let occupying = makeHangingJob()

        // Occupy the only thread with a long-deadline blocking job.
        let occupyingTask = Task { await pool.perform(deadline: Date().addingTimeInterval(60), job: occupying.job) }
        let started = await waitUntil { occupying.didStart.value == true }
        XCTAssertTrue(started, "placeholder job failed to start")

        // This one can only queue and will expire while queued.
        let didRun = AtomicBox<Bool>()
        let queued = await pool.perform(deadline: Date().addingTimeInterval(0.15)) { _ in
            didRun.value = true
            return Self.completeResult
        }

        XCTAssertEqual(queued.completeness, .partial(reasons: [.timedOut]))
        XCTAssertNil(didRun.value, "queued job must not run")
        XCTAssertEqual(pool.abandonedThreads, 0, "no stuck thread means no budget use")
        XCTAssertFalse(pool.isCircuitBroken)

        occupying.release.signal()
        _ = await occupyingTask.value
    }

    // MARK: - Circuit break (fail closed)

    /// Budget exhausted → circuit break → process runs no more sizing: later jobs **do not run at all**
    /// and return partial([.unsupportedVolume]) immediately.
    func testBudgetExhaustionBreaksCircuitAndFailsClosed() async {
        let pool = makePool(maxThreadCount: 3, abandonBudget: 2)

        let first = makeHangingJob(reportingDevice: 1)
        let firstResult = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: first.job)
        XCTAssertEqual(firstResult.completeness, .partial(reasons: [.timedOut]))
        XCTAssertEqual(pool.abandonedThreads, 1)
        XCTAssertFalse(pool.isCircuitBroken)

        let second = makeHangingJob(reportingDevice: 2)
        let secondResult = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: second.job)
        XCTAssertEqual(secondResult.completeness, .partial(reasons: [.timedOut]))
        XCTAssertEqual(pool.abandonedThreads, 2)
        XCTAssertTrue(pool.isCircuitBroken, "exhausted budget must circuit-break")

        // fail closed: no fallback sizer, no retry, refuse immediately.
        let didRun = AtomicBox<Bool>()
        let afterBreak = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in
            didRun.value = true
            return Self.completeResult
        }

        XCTAssertEqual(afterBreak.completeness, .partial(reasons: [.unsupportedVolume]))
        XCTAssertNil(didRun.value, "must not run any sizing job after circuit break")
        XCTAssertNil(afterBreak.rootIdentity)

        // Circuit break does not auto-recover.
        let stillBroken = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in Self.completeResult }
        XCTAssertEqual(stillBroken.completeness, .partial(reasons: [.unsupportedVolume]))
        XCTAssertTrue(pool.isCircuitBroken)
    }

    /// After circuit break, jobs already queued are also fail-closed.
    func testCircuitBreakDrainsQueuedJobs() async {
        let pool = makePool(maxThreadCount: 1, abandonBudget: 1)
        let occupying = makeHangingJob(reportingDevice: 5)

        let occupyingTask = Task { await pool.perform(deadline: Date().addingTimeInterval(0.3), job: occupying.job) }
        let started = await waitUntil { occupying.didStart.value == true }
        XCTAssertTrue(started)

        let didRun = AtomicBox<Bool>()
        let queuedTask = Task {
            await pool.perform(deadline: Date().addingTimeInterval(60)) { _ in
                didRun.value = true
                return Self.completeResult
            }
        }

        let occupyingResult = await occupyingTask.value
        XCTAssertEqual(occupyingResult.completeness, .partial(reasons: [.timedOut]))
        XCTAssertTrue(pool.isCircuitBroken)

        let queuedResult = await queuedTask.value
        XCTAssertEqual(queuedResult.completeness, .partial(reasons: [.unsupportedVolume]))
        XCTAssertNil(didRun.value, "queued jobs during circuit break must also be fail-closed")
    }

    // MARK: - Cancellation

    /// Task cancellation cannot interrupt a blocking syscall, but must reach the job via `isCancelled`
    /// so it exits at the next checkpoint.
    func testCancellationReachesRunningJob() async {
        let pool = makePool()
        let didStart = AtomicBox<Bool>()
        let sawCancellation = AtomicBox<Bool>()

        let task = Task {
            await pool.perform(deadline: Date().addingTimeInterval(60)) { context in
                didStart.value = true
                while !context.isCancelled() {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                sawCancellation.value = true
                return Self.completeResult
            }
        }

        let started = await waitUntil { didStart.value == true }
        XCTAssertTrue(started)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(sawCancellation.value, true, "job must observe cancellation")
        XCTAssertEqual(result.completeness, .complete, "job-returned result should win the gate")
    }

    // MARK: - Helpers

    private static var completeResult: DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: 1,
            fileCount: 1,
            completeness: .complete,
            rootIdentity: nil,
            observedAt: Date()
        )
    }

    private func makePool(maxThreadCount: Int = 3, abandonBudget: Int = 3) -> DiskCleanWorkerPool {
        let pool = DiskCleanWorkerPool(maxThreadCount: maxThreadCount, abandonBudget: abandonBudget)
        pools.append(pool)
        return pool
    }

    /// Build a permanently stuck job simulating a walker blocked in an uninterruptible syscall.
    private func makeHangingJob(reportingDevice device: UInt64? = nil) -> HangingJob {
        let release = DispatchSemaphore(value: 0)
        releaseSemaphores.append(release)
        let didStart = AtomicBox<Bool>()
        let didFinish = AtomicBox<Bool>()

        let job: DiskCleanSizingJob = { context in
            if let device {
                _ = context.admitDevice(device)
            }
            didStart.value = true
            release.wait()
            didFinish.value = true
            return DiskCleanWorkerPoolTests.completeResult
        }
        return HangingJob(job: job, release: release, didStart: didStart, didFinish: didFinish)
    }

    /// Async poll wait so async tests avoid blocking cooperative threads.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private struct HangingJob {
        let job: DiskCleanSizingJob
        let release: DispatchSemaphore
        let didStart: AtomicBox<Bool>
        let didFinish: AtomicBox<Bool>
    }
}

// MARK: - Test concurrency primitives

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class AtomicBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Records concurrency peak.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highWaterMark = 0
    private var runs = 0

    func enter() {
        lock.lock()
        current += 1
        runs += 1
        highWaterMark = max(highWaterMark, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return highWaterMark
    }

    var totalRuns: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }
}

private final class RecordingSizer: DiskCleanDirectorySizing, @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    private var deadline: Date?

    var observedPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    var observedDeadline: Date? {
        lock.lock()
        defer { lock.unlock() }
        return deadline
    }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        lock.lock()
        self.path = path
        self.deadline = context.deadline
        lock.unlock()
        return DiskCleanSizeResult(
            estimatedBytes: 0,
            fileCount: 0,
            completeness: .complete,
            rootIdentity: nil,
            observedAt: Date()
        )
    }
}
