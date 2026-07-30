import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanWorkerPoolTests: XCTestCase {
    /// 所有被测池都登记在此，teardown 统一收尾，避免测试进程堆积空转线程。
    private var pools: [DiskCleanWorkerPool] = []
    /// 用于释放被故意卡住的作业，teardown 必须全部 signal，否则线程永久滞留。
    private var releaseSemaphores: [DispatchSemaphore] = []

    override func tearDown() {
        for semaphore in releaseSemaphores {
            // 多 signal 无害，确保卡住的作业都能收尾退出。
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

    // MARK: - exactly-once 门：双向竞争

    /// 超时与作业完成双向竞争：无论多少并发调用者，`resolve` 只能有一个赢家，
    /// resume 只能发生一次。重复多轮以提高撞上竞态的概率。
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

            XCTAssertEqual(winnerCount.value, 1, "第 \(round) 轮应恰好一个赢家")
            XCTAssertEqual(resumeCount.value, 1, "第 \(round) 轮 resume 只能发生一次")
            XCTAssertTrue(gate.isResolved)
        }
    }

    /// 输掉竞争的一方不得 resume，也不得改写已定的结果。
    func testLosingContenderDoesNotResume() {
        let delivered = AtomicBox<Int>()
        let gate = DiskCleanResumeGate<Int> { delivered.value = $0 }

        XCTAssertTrue(gate.resolve(with: 1))
        XCTAssertFalse(gate.resolve(with: 2))
        XCTAssertFalse(gate.claim())
        XCTAssertEqual(delivered.value, 1)
    }

    // MARK: - 正常路径

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

        XCTAssertLessThanOrEqual(concurrency.peak, 3, "常驻线程上限 3，并发度不得超过它")
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

    // MARK: - 超时、放弃与设备黑名单

    /// 作业滞留在不可中断的调用里 → 超时赢下竞争，线程被放弃，其设备进黑名单。
    func testTimeoutAbandonsThreadAndBlocklistsReportedDevice() async {
        let pool = makePool(maxThreadCount: 3, abandonBudget: 3)
        let hanging = makeHangingJob(reportingDevice: 42)

        let result = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: hanging.job)

        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]))
        XCTAssertEqual(pool.abandonedThreads, 1, "滞留线程必须被计入放弃预算")
        XCTAssertFalse(pool.isCircuitBroken, "预算 3 用掉 1，还不该熔断")

        // 黑名单命中：后续作业上报同一设备时被拒，须立即放弃。
        let admitted = AtomicBox<Bool>()
        _ = await pool.perform(deadline: Date().addingTimeInterval(5)) { context in
            admitted.value = context.admitDevice(42)
            return Self.completeResult
        }
        XCTAssertEqual(admitted.value, false, "已放弃线程所在设备必须被拉黑")

        // 其它设备不受影响。
        let otherAdmitted = AtomicBox<Bool>()
        _ = await pool.perform(deadline: Date().addingTimeInterval(5)) { context in
            otherAdmitted.value = context.admitDevice(7)
            return Self.completeResult
        }
        XCTAssertEqual(otherAdmitted.value, true, "健康设备不应被连坐")
    }

    /// 滞留作业最终返回时，其结果必须被就地丢弃（门已被超时占据），
    /// 且绝不能二次 resume continuation（那会直接崩溃）。
    func testLateJobResultIsDiscardedWithoutDoubleResume() async {
        let pool = makePool(maxThreadCount: 3, abandonBudget: 3)
        let hanging = makeHangingJob()

        let result = await pool.perform(deadline: Date().addingTimeInterval(0.15), job: hanging.job)
        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]))

        // 放行滞留作业，让它走完"结果自持有并丢弃"的路径。
        hanging.release.signal()
        let finished = await waitUntil { hanging.didFinish.value == true }
        XCTAssertTrue(finished, "滞留作业应能自行收尾退出")

        // 池仍然可用（放弃的线程被新线程补上）。
        let next = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in Self.completeResult }
        XCTAssertEqual(next.completeness, .complete)
    }

    /// 排队中就超时的作业没有卡住任何线程 → 不得消耗放弃预算。
    func testTimeoutOfQueuedJobDoesNotConsumeAbandonBudget() async {
        let pool = makePool(maxThreadCount: 1, abandonBudget: 3)
        let occupying = makeHangingJob()

        // 用唯一的线程跑一个长 deadline 的阻塞作业。
        let occupyingTask = Task { await pool.perform(deadline: Date().addingTimeInterval(60), job: occupying.job) }
        let started = await waitUntil { occupying.didStart.value == true }
        XCTAssertTrue(started, "占位作业未能开始执行")

        // 这一个只能排队，且会在队列里到期。
        let didRun = AtomicBox<Bool>()
        let queued = await pool.perform(deadline: Date().addingTimeInterval(0.15)) { _ in
            didRun.value = true
            return Self.completeResult
        }

        XCTAssertEqual(queued.completeness, .partial(reasons: [.timedOut]))
        XCTAssertNil(didRun.value, "排队作业不该被执行")
        XCTAssertEqual(pool.abandonedThreads, 0, "没有线程被卡住，不该动用预算")
        XCTAssertFalse(pool.isCircuitBroken)

        occupying.release.signal()
        _ = await occupyingTask.value
    }

    // MARK: - 熔断（fail closed）

    /// 预算耗尽 → 熔断 → 本进程不再执行任何 sizing：后续作业**根本不运行**，
    /// 直接返回 partial([.unsupportedVolume])。
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
        XCTAssertTrue(pool.isCircuitBroken, "预算耗尽必须熔断")

        // fail closed：不换回退 sizer、不重试，直接拒绝。
        let didRun = AtomicBox<Bool>()
        let afterBreak = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in
            didRun.value = true
            return Self.completeResult
        }

        XCTAssertEqual(afterBreak.completeness, .partial(reasons: [.unsupportedVolume]))
        XCTAssertNil(didRun.value, "熔断后不得再执行任何 sizing 作业")
        XCTAssertNil(afterBreak.rootIdentity)

        // 熔断不自动恢复。
        let stillBroken = await pool.perform(deadline: Date().addingTimeInterval(5)) { _ in Self.completeResult }
        XCTAssertEqual(stillBroken.completeness, .partial(reasons: [.unsupportedVolume]))
        XCTAssertTrue(pool.isCircuitBroken)
    }

    /// 熔断后连"已经在队列里"的作业也一并 fail closed。
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
        XCTAssertNil(didRun.value, "熔断时排队的作业也必须被 fail closed")
    }

    // MARK: - 取消

    /// Task 取消无法中断阻塞 syscall，但必须能通过 `isCancelled` 传达给作业，
    /// 让它在下一个检查点自行退出。
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

        XCTAssertEqual(sawCancellation.value, true, "作业必须能观察到取消")
        XCTAssertEqual(result.completeness, .complete, "作业自行返回的结果应赢下门")
    }

    // MARK: - 辅助

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

    /// 构造一个会一直卡住的作业，模拟滞留在不可中断 syscall 中的 walker。
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

    /// 异步轮询等待，避免在 async 测试里做阻塞等待而占住协作线程。
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

// MARK: - 测试用并发原语

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

/// 记录并发峰值。
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
