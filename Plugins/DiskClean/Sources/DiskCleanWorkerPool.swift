import Darwin
import Foundation
import os

/// exactly-once resume 门（设计 §3.4）。
///
/// 超时计时与 worker 完成**双向竞争**：谁先到谁 resume continuation；后到者只得知自己输了，
/// 既不 resume 也不触碰对方内存（worker 的结果由 worker 自己持有，输了就地丢弃）。
/// 这是把"阻塞 syscall 无法被取消"与"continuation 只能 resume 一次"两个硬约束缝合起来的唯一安全方式。
final class DiskCleanResumeGate<Value: Sendable>: Sendable {
    private let isResolvedLock = OSAllocatedUnfairLock(initialState: false)
    private let resumeHandler: @Sendable (Value) -> Void

    init(resume: @escaping @Sendable (Value) -> Void) {
        self.resumeHandler = resume
    }

    /// 抢占 resume 权。true = 本次调用赢得竞争，**必须**随后恰好调用一次 `deliver`。
    ///
    /// 与 `resolve` 分开是为了让赢家能在 resume **之前**先把自己的账做完
    /// （超时方需要先记放弃预算、拉黑设备），否则等待方可能先看到结果、再看到状态更新。
    func claim() -> Bool {
        isResolvedLock.withLock { isResolved -> Bool in
            if isResolved { return false }
            isResolved = true
            return true
        }
    }

    /// 交付结果并 resume。只允许由 `claim()` 返回 true 的调用方调用一次。
    func deliver(_ value: Value) {
        resumeHandler(value)
    }

    /// 返回 true = 本次调用赢得竞争并已 resume；false = 对方已先行，调用方必须丢弃 `value`。
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

/// 一次阻塞式 sizing 作业。
typealias DiskCleanSizingJob = @Sendable (DiskCleanSizingContext) -> DiskCleanSizeResult

/// 常驻线程池（设计 §3.4）。
///
/// 为什么不用 GCD / Swift 并发：Swift task 取消无法中断阻塞 syscall，GCD 并发队列也没有
/// "放弃某条线程并补充新线程"的接口。病态文件系统上 `getattrlistbulk` 可能永不返回，
/// 必须能把那条线程连同它滞留的调用一起放弃掉，因此自持 `Thread` 池。
///
/// 放弃预算与熔断是**进程级**的：`shared` 单例跨扫描累计放弃次数，耗尽后 fail closed
/// ——本进程不再执行任何 sizing（Fast/Slow 一律停），后续候选全部 `partial([.unsupportedVolume])`
/// 因而不可清理。不自动恢复：病态文件系统重试只会继续烧预算；也不换回退 sizer 续跑
/// ——它同样会阻塞，与"泄漏上限"矛盾。
final class DiskCleanWorkerPool: @unchecked Sendable {
    static let shared = DiskCleanWorkerPool()

    private let maxThreadCount: Int
    private let abandonBudget: Int
    private let timeoutQueue: DispatchQueue

    /// 保护以下全部可变状态，同时用于 worker 线程的取活等待。
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

    /// 熔断状态。扫描引擎据此上报 `walkerCircuitBroken` limitation。
    var isCircuitBroken: Bool {
        condition.lock()
        defer { condition.unlock() }
        return circuitBroken
    }

    /// 累计放弃线程数。扫描引擎据此上报 `threadsAbandoned` limitation。
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

    /// 仅供测试：让常驻线程退出，避免测试进程里堆积空转线程。
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

    // MARK: - 派发

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

    // MARK: - worker 线程

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
            // 熔断可能发生在入队与取活之间：fail closed。
            if circuitBroken {
                condition.unlock()
                item.cancelTimeout()
                item.gate.resolve(with: Self.circuitBrokenResult())
                continue
            }
            item.runningThread = worker
            condition.unlock()

            let result = item.job(makeContext(for: item))

            // 结果自持有：门若已被超时抢占，resolve 返回 false，result 就地丢弃。
            item.gate.resolve(with: result)
            item.cancelTimeout()

            condition.lock()
            item.runningThread = nil
            let wasAbandoned = worker.isAbandoned
            condition.unlock()

            // 被放弃的线程完成滞留调用后直接退出，不再取新活（liveThreadCount 已在放弃时扣减）。
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
        // 上报设备号，供超时放弃时把病态设备拉黑。
        item.reportedDevice = device
        return !circuitBroken && !blockedDevices.contains(device)
    }

    // MARK: - 超时、放弃与熔断

    private func handleTimeout(_ item: WorkItem) {
        // 先争夺 resume 权：只有真正赢下竞争的超时才需要做放弃线程的账。
        // 账必须在 deliver 之前做完，等待方才不会先看到结果、后看到熔断状态。
        guard item.gate.claim() else { return }

        condition.lock()

        // 任务还在队列里没轮到执行 → 没有线程被卡住，只摘除，不消耗预算。
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

        // 线程滞留在无法中断的 syscall 里：放弃它，补充新线程。
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
            // fail closed：连排队中的任务也不再执行。
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

        // 状态已落定，现在才交付结果。
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

    // MARK: - 内部类型

    /// 可变字段由 `condition` 保护。
    private final class WorkItem: @unchecked Sendable {
        let gate: DiskCleanResumeGate<DiskCleanSizeResult>
        let job: DiskCleanSizingJob
        let deadline: Date
        let cancellation: DiskCleanCancellationFlag

        var runningThread: WorkerThread?
        var reportedDevice: UInt64?
        /// `DispatchWorkItem` 不是 Sendable，故用独立 NSLock 保护，不占用池的 condition。
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
        /// 由 `condition` 保护。
        private(set) var isAbandoned = false

        func markAbandoned() {
            isAbandoned = true
        }
    }
}

/// 取消标志。`withTaskCancellationHandler` 在任意线程置位，worker 线程按批读取。
final class DiskCleanCancellationFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    func set() {
        flag.withLock { $0 = true }
    }

    var isSet: Bool {
        flag.withLock { $0 }
    }
}
