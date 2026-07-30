import Foundation
import os
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

// MARK: - 结果与身份工厂

extension DiskCleanRootIdentity {
    static func test(
        devid: UInt64 = 1,
        fileID: UInt64 = 2,
        mtime: Date = Date(timeIntervalSince1970: 1_000),
        fileType: DiskCleanRootIdentity.FileType = .directory
    ) -> DiskCleanRootIdentity {
        DiskCleanRootIdentity(devid: devid, fileID: fileID, mtime: mtime, fileType: fileType)
    }
}

extension DiskCleanSizeResult {
    static func testComplete(
        bytes: Int64 = 100,
        fileCount: Int = 1,
        identity: DiskCleanRootIdentity = .test(),
        observedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: bytes,
            fileCount: fileCount,
            completeness: .complete,
            rootIdentity: identity,
            observedAt: observedAt
        )
    }

    static func testPartial(
        reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        bytes: Int64 = 0,
        identity: DiskCleanRootIdentity? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: bytes,
            fileCount: 0,
            completeness: .partial(reasons: reasons),
            rootIdentity: identity,
            observedAt: observedAt
        )
    }
}

extension DiskCleanFileItem {
    static func testDirectory(_ path: String) -> DiskCleanFileItem {
        DiskCleanFileItem(path: path, isDirectory: true, isSymlink: false, resolvedSymlinkTarget: nil)
    }

    static func testFile(_ path: String) -> DiskCleanFileItem {
        DiskCleanFileItem(path: path, isDirectory: false, isSymlink: false, resolvedSymlinkTarget: nil)
    }
}

extension DiskCleanRuleTarget {
    /// P2 合成 target。`external` 与 glob/provider 互斥，因此单独一个工厂而不是再加一个参数。
    static func testExternal(
        id: String,
        category: DiskCleanCategoryID = .developerArtifacts,
        risk: DiskCleanRisk = .medium,
        reservedRootPaths: [String] = []
    ) -> DiskCleanRuleTarget {
        DiskCleanRuleTarget(
            id: id,
            legacyRuleID: id,
            category: category,
            risk: risk,
            kind: .external,
            reservedRootPaths: reservedRootPaths
        )
    }

    static func test(
        id: String,
        legacyRuleID: String? = nil,
        category: DiskCleanCategoryID = .appCaches,
        risk: DiskCleanRisk = .low,
        globs: [String] = [],
        provider: (any DiskCleanDynamicRuleProviding)? = nil,
        reservedRootPaths: [String] = ["/reserved"],
        requiresFullDiskAccess: Bool = false,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) -> DiskCleanRuleTarget {
        DiskCleanRuleTarget(
            id: id,
            legacyRuleID: legacyRuleID ?? id,
            category: category,
            risk: risk,
            kind: provider.map { DiskCleanRuleTarget.Kind.dynamic(provider: $0) } ?? .path(globs: globs),
            reservedRootPaths: reservedRootPaths,
            requiresFullDiskAccess: requiresFullDiskAccess,
            lockedByBundleIDs: lockedByBundleIDs,
            skipWhenProcessIsRunning: skipWhenProcessIsRunning
        )
    }
}

// MARK: - 可编程文件系统

/// 纯内存文件系统。引擎的展开阶段只需要"glob → 命中项"与"路径 → 直接子项"两张表。
final class FakeDiskCleanFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var itemsByPattern: [String: [DiskCleanFileItem]] = [:]
    private var childrenByPath: [String: [DiskCleanFileItem]] = [:]
    private var patternErrors: [String: Error] = [:]
    private var unlistablePaths: Set<String> = []

    func setItems(_ items: [DiskCleanFileItem], forPattern pattern: String) {
        lock.withLock { itemsByPattern[pattern] = items }
    }

    func setChildren(_ children: [DiskCleanFileItem], of path: String) {
        lock.withLock { childrenByPath[path] = children }
    }

    func setError(_ error: Error, forPattern pattern: String) {
        lock.withLock { patternErrors[pattern] = error }
    }

    func markUnlistable(_ path: String) {
        lock.withLock { _ = unlistablePaths.insert(path) }
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        let (items, error) = lock.withLock { (itemsByPattern[pattern] ?? [], patternErrors[pattern]) }
        if let error { throw error }
        return items
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        lock.withLock { itemsByPattern.values.flatMap { $0 }.first { $0.path == path } }
    }

    func directChildren(of path: String) throws -> [DiskCleanFileItem] {
        let (children, isUnlistable) = lock.withLock {
            (childrenByPath[path] ?? [], unlistablePaths.contains(path))
        }
        if isUnlistable { throw FakeFileSystemError.unlistable(path) }
        return children
    }

    func removeItem(at path: String) throws {}

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        paths
    }

    enum FakeFileSystemError: Error, Equatable {
        case unlistable(String)
    }
}

struct FakeDiskCleanExpansionError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

struct FakeFailingDynamicRuleProvider: DiskCleanDynamicRuleProviding {
    let error: Error

    init(error: Error = FakeDiskCleanExpansionError(message: "provider exploded")) {
        self.error = error
    }

    func expand() async throws -> [DiskCleanFileItem] {
        throw error
    }
}

struct FakeStaticDynamicRuleProvider: DiskCleanDynamicRuleProviding {
    let items: [DiskCleanFileItem]

    func expand() async throws -> [DiskCleanFileItem] {
        items
    }
}

// MARK: - sizing 执行 seam

/// 可编程 sizing 执行器：记录并发峰值、请求顺序与 deadline，可注入延迟与熔断状态。
///
/// 不启真实线程，因此并发上限测的是**引擎 TaskGroup 的滑动窗口**，与 WorkerPool 的线程数无关。
final class FakeDiskCleanSizingExecutor: DiskCleanSizingExecuting, @unchecked Sendable {
    private struct State {
        var resultsByPath: [String: DiskCleanSizeResult] = [:]
        var defaultResult: DiskCleanSizeResult = .testComplete()
        var requestedPaths: [String] = []
        var deadlines: [Date] = []
        var active = 0
        var peakConcurrency = 0
        var isCircuitBroken = false
        var abandonedThreads = 0
    }

    private let lock = NSLock()
    private var state = State()
    /// 每次调用的人为延迟，用于让多个任务真正重叠。
    let delay: Duration?

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func setResult(_ result: DiskCleanSizeResult, forPath path: String) {
        lock.withLock { state.resultsByPath[path] = result }
    }

    func setDefaultResult(_ result: DiskCleanSizeResult) {
        lock.withLock { state.defaultResult = result }
    }

    func setPoolState(isCircuitBroken: Bool, abandonedThreads: Int) {
        lock.withLock {
            state.isCircuitBroken = isCircuitBroken
            state.abandonedThreads = abandonedThreads
        }
    }

    var requestedPaths: [String] { lock.withLock { state.requestedPaths } }
    var deadlines: [Date] { lock.withLock { state.deadlines } }
    var peakConcurrency: Int { lock.withLock { state.peakConcurrency } }
    var isCircuitBroken: Bool { lock.withLock { state.isCircuitBroken } }
    var abandonedThreads: Int { lock.withLock { state.abandonedThreads } }

    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult {
        lock.withLock {
            state.requestedPaths.append(path)
            state.deadlines.append(deadline)
            state.active += 1
            state.peakConcurrency = max(state.peakConcurrency, state.active)
        }
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return lock.withLock {
            state.active -= 1
            return state.resultsByPath[path] ?? state.defaultResult
        }
    }
}

/// 直接在调用方线程上跑 sizer，不经线程池。用于验证引擎与缓存装饰器的接线。
///
/// `now` 单独注入：真实的 sizing 上下文时钟归 WorkerPool 所有（引擎无法把自己的时钟塞进去），
/// 因此测试缓存 TTL 时必须由这里给出与缓存写入时刻同一坐标系的时间。
struct DirectDiskCleanSizingExecutor: DiskCleanSizingExecuting {
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    var isCircuitBroken: Bool { false }
    var abandonedThreads: Int { 0 }

    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult {
        sizer.size(
            ofItemAt: path,
            context: DiskCleanSizingContext(deadline: deadline, now: now)
        )
    }
}

/// 按路径返回预置结果的 sizer，并记录被真正调用的路径（缓存命中时不应被调用）。
final class FakeDiskCleanSizer: DiskCleanDirectorySizing, @unchecked Sendable {
    private let lock = NSLock()
    private var resultsByPath: [String: DiskCleanSizeResult] = [:]
    private var invokedPaths: [String] = []
    /// 阻塞时长。用于验证"单项 deadline 到期 → partial([.timedOut])"的真实超时路径。
    let blockingDuration: TimeInterval

    init(blockingDuration: TimeInterval = 0) {
        self.blockingDuration = blockingDuration
    }

    func setResult(_ result: DiskCleanSizeResult, forPath path: String) {
        lock.withLock { resultsByPath[path] = result }
    }

    var calledPaths: [String] { lock.withLock { invokedPaths } }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        lock.withLock { invokedPaths.append(path) }
        if blockingDuration > 0 {
            Thread.sleep(forTimeInterval: blockingDuration)
        }
        return lock.withLock { resultsByPath[path] } ?? .testComplete()
    }
}

struct FakeDiskCleanRootIdentityProbe: DiskCleanRootIdentityProbing {
    let identitiesByPath: [String: DiskCleanRootIdentity]

    func identity(ofItemAt path: String) -> DiskCleanRootIdentity? {
        identitiesByPath[path]
    }
}

// MARK: - 运行应用快照

struct FakeDiskCleanRunningAppLock: DiskCleanRunningAppSnapshotting {
    let snapshot: DiskCleanRunningAppSnapshot

    init(snapshot: DiskCleanRunningAppSnapshot = DiskCleanRunningAppSnapshot()) {
        self.snapshot = snapshot
    }

    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
        snapshot
    }
}

struct FakeDiskCleanFullDiskAccess: DiskCleanFullDiskAccessProbing {
    let hasFullDiskAccess: Bool
}

/// 可编程文件可读性探针。测试授权矩阵时不碰真实 TCC 保护文件。
struct FakeDiskCleanFileReadability: DiskCleanFileReadabilityProbing {
    /// 可打开的路径集合。不在集合里的一律"打不开"，涵盖被拒绝与文件不存在两种情形——
    /// 探针本身也不区分它们（都无法证明有 FDA）。
    let openablePaths: Set<String>
    /// 记录探测顺序，用于断言"先成功的那条之后不再继续试"。
    private let probed = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(openablePaths: Set<String> = []) {
        self.openablePaths = openablePaths
    }

    var probedPaths: [String] { probed.withLock { $0 } }

    func canOpenForReading(atPath path: String) -> Bool {
        probed.withLock { $0.append(path) }
        return openablePaths.contains(path)
    }
}

// MARK: - P2 展开 seam

/// 可编程的非规则展开来源。让 P2 候选在不碰文件系统的前提下走完整条管线。
struct FakeDiskCleanExternalExpansion: DiskCleanExternalExpanding {
    var hits: [DiskCleanTargetHit] = []
    var reservedRootPaths: [String] = []
    var limitations: [DiskCleanScanLimitation] = []
    var logMessages: [DiskCleanScanLogMessage] = []

    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion {
        var expansion = DiskCleanExternalExpansion()
        expansion.hits = hits
        expansion.reservedRootPaths = reservedRootPaths
        expansion.limitations = limitations
        expansion.logMessages = logMessages
        return expansion
    }
}

// MARK: - 子进程 seam

/// 可编程子进程：记录调用参数，按需返回输出或抛错。
final class FakeDiskCleanSubprocessRunner: DiskCleanSubprocessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executablePath: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []
    private let result: Result<DiskCleanSubprocessResult, Error>

    init(exitCode: Int32 = 0, standardOutput: String = "") {
        self.result = .success(
            DiskCleanSubprocessResult(
                exitCode: exitCode,
                standardOutput: Data(standardOutput.utf8)
            )
        )
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    var invocations: [Invocation] { lock.withLock { recordedInvocations } }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        lock.withLock {
            recordedInvocations.append(Invocation(executablePath: executablePath, arguments: arguments))
        }
        return try result.get()
    }
}

// MARK: - 测试时钟

/// 手动推进的时钟。过期门是时间驱动的，测试必须能在不真等 300 秒的前提下驱动那次转换。
final class TestDiskCleanClock: DiskCleanClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var waiters: [Waiter] = []

    init(now: Date = Date(timeIntervalSince1970: 10_000)) {
        self.current = now
    }

    var now: Date { lock.withLock { current } }

    func sleep(until deadline: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shouldResumeImmediately = lock.withLock { () -> Bool in
                guard current < deadline else { return true }
                waiters.append(Waiter(deadline: deadline, continuation: continuation))
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func advance(by interval: TimeInterval) {
        advance(to: now.addingTimeInterval(interval))
    }

    func advance(to date: Date) {
        let due = lock.withLock { () -> [Waiter] in
            current = date
            let due = waiters.filter { $0.deadline <= date }
            waiters.removeAll { $0.deadline <= date }
            return due
        }
        for waiter in due {
            waiter.continuation.resume()
        }
    }
}

// MARK: - 受控引擎

/// 由测试逐条驱动的事件流。用于验证 operationID 世代、节流发布与过期时钟——
/// 这些行为都依赖"在某个精确时刻还没结束"的状态。
final class ControlledDiskCleanScanEngine: DiskCleanScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation?
    private var scanCalls: [(scope: DiskCleanScanScope, forceRefresh: Bool)] = []
    private var isTerminated = false

    var scanCallCount: Int { lock.withLock { scanCalls.count } }
    var lastForceRefresh: Bool? { lock.withLock { scanCalls.last?.forceRefresh } }
    var lastScope: DiskCleanScanScope? { lock.withLock { scanCalls.last?.scope } }
    var lastChoices: Set<DiskCleanChoice>? { lock.withLock { scanCalls.last?.scope.choices } }
    var didTerminate: Bool { lock.withLock { isTerminated } }

    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        lock.withLock {
            scanCalls.append((scope: scope, forceRefresh: forceRefresh))
            isTerminated = false
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.isTerminated = true }
            }
        }
    }

    func emit(_ event: DiskCleanScanEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }

    func fail(with error: Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }
}

/// 记录调用的执行器 fake。执行器只接受 `ValidatedPlan`，故 fake 记录的是收到的计划。
final class FakeDiskCleanExecutor: DiskCleanExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [DiskCleanValidatedPlan] = []
    private var failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    var callCount: Int { lock.withLock { plans.count } }
    var lastPlan: DiskCleanValidatedPlan? { lock.withLock { plans.last } }
    var lastSelectedIDs: Set<DiskCleanCandidate.ID>? {
        lock.withLock { plans.last.map { Set($0.items.map(\.candidateID)) } }
    }
    var lastMode: DiskCleanRemovalMode? { lock.withLock { plans.last?.mode } }

    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        let failure = lock.withLock { () -> Error? in
            plans.append(plan)
            return self.failure
        }
        if let failure { throw failure }
        return DiskCleanExecutionResult(
            itemResults: plan.items.map {
                DiskCleanExecutionItemResult(
                    candidateID: $0.candidateID,
                    path: $0.path,
                    outcome: plan.mode == .trash
                        ? .trashed(reclaimedBytes: $0.estimatedBytes, stagedName: ".mactools-staged-test")
                        : .removed(reclaimedBytes: $0.estimatedBytes)
                )
            },
            mode: plan.mode
        )
    }
}

/// 内存删除方式存储。真实实现写 `UserDefaults`，测试绝不碰用户偏好。
final class InMemoryDiskCleanRemovalModeStore: DiskCleanRemovalModeStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: DiskCleanRemovalMode

    init(mode: DiskCleanRemovalMode = .trash) {
        self.mode = mode
    }

    var savedMode: DiskCleanRemovalMode { lock.withLock { mode } }

    func load() -> DiskCleanRemovalMode { lock.withLock { mode } }

    func save(_ mode: DiskCleanRemovalMode) {
        lock.withLock { self.mode = mode }
    }
}

/// 内存扫描根存储。同上：绝不碰 `UserDefaults.standard` 里用户真实配置的文件夹。
final class EphemeralPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String]

    init(roots: [String] = []) {
        self.roots = roots
    }

    func loadRoots() -> [String] { lock.withLock { roots } }

    func saveRoots(_ roots: [String]) {
        lock.withLock { self.roots = roots }
    }
}

// MARK: - 异步断言工具

/// 轮询等待条件成立。异步状态转换（节流发布、过期任务）无法靠固定 sleep 稳定断言。
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ description: String,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("等待超时：\(description)", file: file, line: line)
}
