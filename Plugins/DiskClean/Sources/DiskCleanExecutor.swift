import Foundation

// MARK: - 执行接口

/// 执行器只接受 `DiskCleanValidatedPlan`（设计 §6.1、§7）。
///
/// 类型系统在这里承担安全职责：`ValidatedPlan.init` 是 fileprivate，唯一铸造点是
/// `DiskCleanPlanner.makePlan`。没有"传一组路径进来删掉"的入口，也就没有绕过校验的路径。
protocol DiskCleanExecuting: Sendable {
    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult
}

// MARK: - 计划级失败

/// preflight 失败（设计 §7.1）。任一条成立即**整次中止，零删除**。
enum DiskCleanExecutionError: LocalizedError, Equatable {
    case planExpired
    case lockedDuringPreflight(path: String, processName: String)
    case safetyRejected(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .planExpired:
            return "扫描结果已过期，请重新扫描"
        case let .lockedDuringPreflight(path, processName):
            return "\(processName) 正在使用 \(path)，已取消本次清理"
        case let .safetyRejected(path, reason):
            return "\(path) 未通过安全校验（\(reason)），已取消本次清理"
        }
    }
}

// MARK: - 执行结果

struct DiskCleanExecutionItemResult: Equatable, Sendable {
    /// 终态（设计 §7.5）。`changedSinceScan` 与 `rollbackBlocked` 单列，不并进 skipped/failed：
    /// 前者要引导用户重扫，后者要在清理历史里置顶提示，两者的用户动作完全不同。
    enum Outcome: Equatable, Sendable {
        case removed(reclaimedBytes: Int64)
        case trashed(reclaimedBytes: Int64, stagedName: String)
        case skipped(DiskCleanSafetyStatus)
        case changedSinceScan
        case failed(message: String)
        case partiallyDeleted(stagedName: String, message: String)
        case rollbackBlocked(stagedName: String, message: String)
    }

    let candidateID: DiskCleanCandidate.ID
    let path: String
    let outcome: Outcome

    /// 估算回收字节。**不是实际释放空间**（APFS clone / 稀疏文件 / 目录外硬链接），
    /// 文案一律"约 X"，废纸篓模式不得写"已释放"（设计 §7.7）。
    var reclaimedBytes: Int64 {
        switch outcome {
        case let .removed(reclaimedBytes):
            return max(reclaimedBytes, 0)
        case let .trashed(reclaimedBytes, _):
            return max(reclaimedBytes, 0)
        case .skipped, .changedSinceScan, .failed, .partiallyDeleted, .rollbackBlocked:
            return 0
        }
    }

    /// 需要在清理历史里置顶提示的诚实终态。
    var needsAttention: Bool {
        switch outcome {
        case .partiallyDeleted, .rollbackBlocked:
            return true
        case .removed, .trashed, .skipped, .changedSinceScan, .failed:
            return false
        }
    }
}

struct DiskCleanExecutionResult: Equatable, Sendable {
    let itemResults: [DiskCleanExecutionItemResult]
    let mode: DiskCleanRemovalMode

    init(itemResults: [DiskCleanExecutionItemResult], mode: DiskCleanRemovalMode = .trash) {
        self.itemResults = itemResults
        self.mode = mode
    }

    /// 已处置项数：永久删除与移入废纸篓都算成功。
    var removedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .removed, .trashed:
                return true
            case .skipped, .changedSinceScan, .failed, .partiallyDeleted, .rollbackBlocked:
                return false
            }
        }.count
    }

    /// 跳过项数：安全策略拒绝，以及扫描后内容已变化。两者都未触碰对象。
    var skippedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .skipped, .changedSinceScan:
                return true
            case .removed, .trashed, .failed, .partiallyDeleted, .rollbackBlocked:
                return false
            }
        }.count
    }

    /// 未能干净收场的项数。`partiallyDeleted` / `rollbackBlocked` 计入这里——
    /// 它们不是成功，把它们藏进"已清理"才是不诚实。
    var failedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .failed, .partiallyDeleted, .rollbackBlocked:
                return true
            case .removed, .trashed, .skipped, .changedSinceScan:
                return false
            }
        }.count
    }

    var changedSinceScanCount: Int {
        itemResults.filter { $0.outcome == .changedSinceScan }.count
    }

    var attentionResults: [DiskCleanExecutionItemResult] {
        itemResults.filter(\.needsAttention)
    }

    var reclaimedBytes: Int64 {
        itemResults.reduce(0) { $0 + $1.reclaimedBytes }
    }
}

// MARK: - 执行器

/// 计划执行器（设计 §7.1、§7.2）。
///
/// 职责边界：本类型负责**顺序与复核**，真正动文件的只有 `DiskCleanPlanItemRemoving`。
/// 三层防线各自独立：Planner 铸造时校验一次、这里 preflight 与逐项各复核一次、
/// 原语在 fd 上做身份验证。它们不共用判断点，任一层有缺陷都不会让整条链失守。
struct DiskCleanExecutor: DiskCleanExecuting {
    private let primitive: any DiskCleanPlanItemRemoving
    private let safetyPolicy: DiskCleanSafetyPolicy
    private let runningAppLock: any DiskCleanRunningAppSnapshotting
    private let auditLog: DiskCleanAuditLog
    private let now: @Sendable () -> Date

    init(
        storageDirectory: URL = DiskCleanStorageLocation.fallbackDirectory,
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = DiskCleanRunningAppLock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let journal = DiskCleanStagingJournal(directory: storageDirectory)
        self.init(
            primitive: DiskCleanRemovalPrimitive(journal: journal, now: now),
            safetyPolicy: safetyPolicy,
            runningAppLock: runningAppLock,
            auditLog: DiskCleanAuditLog(directory: storageDirectory),
            now: now
        )
    }

    init(
        primitive: any DiskCleanPlanItemRemoving,
        safetyPolicy: DiskCleanSafetyPolicy,
        runningAppLock: any DiskCleanRunningAppSnapshotting,
        auditLog: DiskCleanAuditLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.primitive = primitive
        self.safetyPolicy = safetyPolicy
        self.runningAppLock = runningAppLock
        self.auditLog = auditLog
        self.now = now
    }

    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        var snapshot = try await preflight(plan: plan)

        var itemResults: [DiskCleanExecutionItemResult] = []
        itemResults.reserveCapacity(plan.items.count)

        for item in plan.items {
            try Task.checkCancellation()

            // 逐项复核锁定：bundle ID 刷新，进程名沿用 preflight 快照（取舍见协议注释）。
            snapshot = await runningAppLock.refreshingBundleIDs(in: snapshot)
            if let processName = snapshot.lockingProcessName(
                bundleIDs: item.lockedByBundleIDs,
                processNames: item.skipWhenProcessIsRunning
            ) {
                itemResults.append(
                    record(item: item, outcome: .skipped(.inUse(processName: processName)), mode: plan.mode)
                )
                continue
            }

            // SafetyPolicy 二次校验：白名单可能在扫描后新增，暂存名保护也在这里生效。
            let safety = safetyPolicy.safetyStatus(for: item.path)
            guard safety.isCleanable else {
                itemResults.append(record(item: item, outcome: .skipped(safety), mode: plan.mode))
                continue
            }

            let disposition = primitive.remove(item, mode: plan.mode)
            itemResults.append(
                record(item: item, outcome: Self.outcome(for: disposition, item: item), mode: plan.mode)
            )
        }

        return DiskCleanExecutionResult(itemResults: itemResults, mode: plan.mode)
    }

    // MARK: - preflight（§7.1）

    private func preflight(plan: DiskCleanValidatedPlan) async throws -> DiskCleanRunningAppSnapshot {
        // 1. 过期复核。确认窗口不得越过过期时刻，但时钟仍以执行时刻为准。
        guard now() < plan.expiryDeadline else {
            throw DiskCleanExecutionError.planExpired
        }

        // 2. 新快照 + 全体计划项的锁定 / 安全预检。任一项不过关，整次中止。
        let processNames = Array(Set(plan.items.flatMap(\.skipWhenProcessIsRunning)))
        let snapshot = await runningAppLock.makeSnapshot(processNames: processNames)
        for item in plan.items {
            if let processName = snapshot.lockingProcessName(
                bundleIDs: item.lockedByBundleIDs,
                processNames: item.skipWhenProcessIsRunning
            ) {
                throw DiskCleanExecutionError.lockedDuringPreflight(path: item.path, processName: processName)
            }
            let safety = safetyPolicy.safetyStatus(for: item.path)
            guard safety.isCleanable else {
                throw DiskCleanExecutionError.safetyRejected(
                    path: item.path,
                    reason: Self.describe(safety)
                )
            }
        }

        // 3. 用计划自带的证据重跑祖先断言。证据在计划内，可独立复核——这道防线防的是
        //    Planner 自身的缺陷，纯内存比对，代价可忽略。
        try DiskCleanPlanner.assertNoAncestorViolation(
            plannedPaths: plan.items.map(\.path),
            exclusionPaths: plan.exclusionPaths,
            reservedPrefixes: plan.reservedPrefixes
        )

        return snapshot
    }

    // MARK: - 终态映射与审计

    private static func outcome(
        for disposition: DiskCleanRemovalDisposition,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> DiskCleanExecutionItemResult.Outcome {
        switch disposition {
        case .removed:
            return .removed(reclaimedBytes: item.estimatedBytes)
        case let .trashed(stagedName):
            return .trashed(reclaimedBytes: item.estimatedBytes, stagedName: stagedName)
        case .changedSinceScan:
            return .changedSinceScan
        case let .failed(reason):
            return .failed(message: reason)
        case let .partiallyDeleted(stagedName, reason):
            return .partiallyDeleted(stagedName: stagedName, message: reason)
        case let .rollbackBlocked(stagedName, reason):
            return .rollbackBlocked(stagedName: stagedName, message: reason)
        }
    }

    private func record(
        item: DiskCleanValidatedPlan.PlanItem,
        outcome: DiskCleanExecutionItemResult.Outcome,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanExecutionItemResult {
        auditLog.append(
            DiskCleanAuditLog.Record(
                timestamp: now(),
                action: mode == .trash ? .trash : .delete,
                targetID: item.targetID,
                legacyRuleID: item.legacyRuleID,
                category: item.category.rawValue,
                path: item.path,
                stagedName: Self.stagedName(of: outcome),
                estimatedBytes: item.estimatedBytes,
                status: Self.status(of: outcome),
                skipReason: Self.skipReason(of: outcome),
                error: Self.errorMessage(of: outcome)
            )
        )
        return DiskCleanExecutionItemResult(
            candidateID: item.candidateID,
            path: item.path,
            outcome: outcome
        )
    }

    private static func stagedName(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .trashed(_, stagedName),
             let .partiallyDeleted(stagedName, _),
             let .rollbackBlocked(stagedName, _):
            return stagedName
        case .removed, .skipped, .changedSinceScan, .failed:
            return nil
        }
    }

    private static func status(of outcome: DiskCleanExecutionItemResult.Outcome) -> String {
        switch outcome {
        case .removed, .trashed:
            return "ok"
        case .skipped:
            return "skipped"
        case .changedSinceScan:
            return "changedSinceScan"
        case .failed:
            return "failed"
        case .partiallyDeleted:
            return "partiallyDeleted"
        case .rollbackBlocked:
            return "rollbackBlocked"
        }
    }

    private static func skipReason(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        guard case let .skipped(safety) = outcome else { return nil }
        return describe(safety)
    }

    private static func errorMessage(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .failed(message),
             let .partiallyDeleted(_, message),
             let .rollbackBlocked(_, message):
            return message
        case .removed, .trashed, .skipped, .changedSinceScan:
            return nil
        }
    }

    private static func describe(_ safety: DiskCleanSafetyStatus) -> String {
        switch safety {
        case .allowed:
            return "allowed"
        case let .whitelisted(rule):
            return "whitelisted(\(rule))"
        case let .protected(reason):
            return "protected(\(reason))"
        case let .invalid(reason):
            return "invalid(\(reason))"
        case let .requiresAdmin(reason):
            return "requiresAdmin(\(reason))"
        case let .inUse(processName):
            return "inUse(\(processName))"
        }
    }
}
