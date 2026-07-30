import Foundation

// MARK: - 删除方式

/// 删除方式（设计 §7.4）。两种模式都走 freeze 原语；差异只在冻结后的处置。
enum DiskCleanRemovalMode: String, CaseIterable, Equatable, Sendable {
    /// 移到废纸篓（默认）。可恢复，单步执行。
    case trash
    /// 永久删除。不可逆，必须经 confirming 双步确认。
    case permanent
}

/// 删除方式的持久化 seam。
protocol DiskCleanRemovalModeStoring: Sendable {
    func load() -> DiskCleanRemovalMode
    func save(_ mode: DiskCleanRemovalMode)
}

/// `UserDefaults` 本身线程安全但未标注 Sendable，与仓库既有的
/// `LocalDiskCleanFileSystem` 同一处理方式。
struct UserDefaultsDiskCleanRemovalModeStore: DiskCleanRemovalModeStoring, @unchecked Sendable {
    static let defaultsKey = "DiskClean.removalMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DiskCleanRemovalMode {
        defaults.string(forKey: Self.defaultsKey)
            .flatMap(DiskCleanRemovalMode.init(rawValue:)) ?? .trash
    }

    func save(_ mode: DiskCleanRemovalMode) {
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}

// MARK: - 计划错误

enum DiskCleanPlanError: LocalizedError, Equatable {
    /// 选中了不存在或不可清理的候选。
    case invalidSelection(candidateID: String)
    /// 选中集为空。
    case emptySelection
    /// 候选的 target 在目录中不存在（工件与目录版本不一致）。
    case unknownTarget(targetID: String)
    /// 计划路径是某个排除路径 / 保留前缀的祖先——删除它会吞掉未经审查的子树。
    case ancestorViolation(plannedPath: String, protectedPath: String)
    /// 结果已过期（§4.4 过期门）。
    case resultExpired

    var errorDescription: String? {
        switch self {
        case let .invalidSelection(candidateID):
            return "选择包含不可清理的候选：\(candidateID)"
        case .emptySelection:
            return "没有可执行的清理项"
        case let .unknownTarget(targetID):
            return "规则目录缺少 target：\(targetID)"
        case let .ancestorViolation(plannedPath, protectedPath):
            return "计划路径 \(plannedPath) 覆盖受保护路径 \(protectedPath)"
        case .resultExpired:
            return "扫描结果已过期，请重新扫描"
        }
    }
}

// MARK: - 已验证计划

/// 不可伪造的删除计划（设计 §6.1）。
///
/// `init` 为 **fileprivate**：除同文件的 `DiskCleanPlanner.makePlan` 外无法构造
/// （ticket-mint 模式），执行器只接受本类型。排除集与保留前缀是**计划自带的验证证据**，
/// 执行器 preflight 据此独立重跑祖先断言（§7.1），不必信任 Planner 没有缺陷。
struct DiskCleanValidatedPlan: Equatable, Sendable {
    struct PlanItem: Equatable, Sendable {
        let candidateID: DiskCleanCandidate.ID
        /// 物理路径（不含符号链接祖先，§13-6）。
        let path: String
        let rootIdentity: DiskCleanRootIdentity
        let observedAt: Date
        let targetID: String
        let legacyRuleID: String
        let category: DiskCleanCategoryID
        let estimatedBytes: Int64
        /// 锁定判定所需的 target 声明，铸造时从规则目录复制，执行侧无需再查目录。
        let lockedByBundleIDs: [String]
        let skipWhenProcessIsRunning: [String]

        var parentPath: String {
            (path as NSString).deletingLastPathComponent
        }

        var name: String {
            (path as NSString).lastPathComponent
        }
    }

    let items: [PlanItem]
    /// 冻结的删除方式。confirming 期间的模式变更会作废整个计划，而不是改写此值。
    let mode: DiskCleanRemovalMode
    let totalEstimatedBytes: Int64
    /// 冻结的最早观测时刻。执行 preflight 据此复核过期门（§7.1 第 1 条）。
    let minObservedAt: Date
    /// 验证证据：全体未入计划候选的路径 + 锁定/保护/白名单/partial 路径。
    let exclusionPaths: [String]
    /// 验证证据：被跳过 / 失败 target 的保留根（未扫描子树视为存在）。
    let reservedPrefixes: [String]
    let mintedAt: Date

    fileprivate init(
        items: [PlanItem],
        mode: DiskCleanRemovalMode,
        minObservedAt: Date,
        exclusionPaths: [String],
        reservedPrefixes: [String],
        mintedAt: Date
    ) {
        self.items = items
        self.mode = mode
        self.totalEstimatedBytes = items.reduce(0) { $0 + max($1.estimatedBytes, 0) }
        self.minObservedAt = minObservedAt
        self.exclusionPaths = exclusionPaths
        self.reservedPrefixes = reservedPrefixes
        self.mintedAt = mintedAt
    }

    var itemCount: Int { items.count }

    var expiryDeadline: Date {
        DiskCleanScanFreshness.deadline(minObservedAt: minObservedAt)
    }
}

/// 面向 UI 的计划摘要。快照只携带它，完整计划留在 Controller 私有状态里。
struct DiskCleanPendingPlanSummary: Equatable, Sendable {
    let itemCount: Int
    let totalEstimatedBytes: Int64
    let mode: DiskCleanRemovalMode
}

// MARK: - Planner

/// 计划唯一铸造点。
@MainActor
enum DiskCleanPlanner {
    /// 铸造计划。任一校验失败即 `throw`——不产出计划 = 零删除。
    ///
    /// 排除集与保留前缀一律从 `artifact` 推导；调用方（Controller）只能通过
    /// `selectedIDs` 做减法，无法伪造证据，也无法漏传保留前缀。
    static func makePlan(
        artifact: DiskCleanScanArtifact,
        selectedIDs: Set<DiskCleanCandidate.ID>,
        mode: DiskCleanRemovalMode,
        now: Date,
        catalog: DiskCleanRuleCatalogV2 = .current
    ) throws -> DiskCleanValidatedPlan {
        guard !selectedIDs.isEmpty else {
            throw DiskCleanPlanError.emptySelection
        }

        let targetsByID = Dictionary(
            catalog.targets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [DiskCleanValidatedPlan.PlanItem] = []
        items.reserveCapacity(selectedIDs.count)
        var minObservedAt = Date.distantFuture

        // 选中集顺序按工件里的候选顺序，保证执行与展示一致且可复现。
        for candidate in artifact.candidates where selectedIDs.contains(candidate.id) {
            guard candidate.isCleanable,
                  let sizeResult = candidate.sizeResult,
                  let rootIdentity = sizeResult.rootIdentity else {
                throw DiskCleanPlanError.invalidSelection(candidateID: candidate.id)
            }
            guard let target = targetsByID[candidate.targetID] else {
                throw DiskCleanPlanError.unknownTarget(targetID: candidate.targetID)
            }

            minObservedAt = min(minObservedAt, sizeResult.observedAt)
            items.append(
                DiskCleanValidatedPlan.PlanItem(
                    candidateID: candidate.id,
                    path: candidate.path,
                    rootIdentity: rootIdentity,
                    observedAt: sizeResult.observedAt,
                    targetID: candidate.targetID,
                    legacyRuleID: candidate.legacyRuleID,
                    category: candidate.category,
                    estimatedBytes: candidate.estimatedBytes,
                    lockedByBundleIDs: target.lockedByBundleIDs,
                    skipWhenProcessIsRunning: target.skipWhenProcessIsRunning
                )
            )
        }

        // 递进来的 id 有一部分不在工件里 → 越权选择，整体拒绝。
        // 按集合而非数量比对：工件里若出现重复 id，数量相等也可能掩盖一个未命中的选择。
        let plannedIDs = Set(items.map(\.candidateID))
        guard plannedIDs == selectedIDs else {
            let unknownID = selectedIDs.first { !plannedIDs.contains($0) } ?? "?"
            throw DiskCleanPlanError.invalidSelection(candidateID: unknownID)
        }

        // 过期校验（§6.1 第 4 条）。
        guard now < DiskCleanScanFreshness.deadline(minObservedAt: minObservedAt) else {
            throw DiskCleanPlanError.resultExpired
        }

        // 排除集：全体未入计划的候选路径。锁定/保护/白名单/partial 天然包含在内——
        // 它们不可清理，必然不在计划里。
        let exclusionPaths = artifact.candidates
            .filter { !plannedIDs.contains($0.id) }
            .map(\.path)
        let reservedPrefixes = artifact.reservedRootPaths

        // 祖先断言（§6.1 第 3 条）。
        try assertNoAncestorViolation(
            plannedPaths: items.map(\.path),
            exclusionPaths: exclusionPaths,
            reservedPrefixes: reservedPrefixes
        )

        return DiskCleanValidatedPlan(
            items: items,
            mode: mode,
            minObservedAt: minObservedAt,
            exclusionPaths: exclusionPaths,
            reservedPrefixes: reservedPrefixes,
            mintedAt: now
        )
    }

    /// 祖先断言：任何计划路径不得等于、或是任何受保护路径的祖先。
    ///
    /// 执行器 preflight 用计划自带的证据重跑同一断言（§7.1 第 3 条），共用此实现。
    /// `nonisolated`：这是对值类型的纯计算，执行器在主线程之外重跑它不该被迫跳回主 actor。
    nonisolated static func assertNoAncestorViolation(
        plannedPaths: [String],
        exclusionPaths: [String],
        reservedPrefixes: [String]
    ) throws {
        let protectedPaths = exclusionPaths + reservedPrefixes
        for planned in plannedPaths {
            let prefix = planned.hasSuffix("/") ? planned : planned + "/"
            for protectedPath in protectedPaths {
                if protectedPath == planned || protectedPath.hasPrefix(prefix) {
                    throw DiskCleanPlanError.ancestorViolation(
                        plannedPath: planned,
                        protectedPath: protectedPath
                    )
                }
            }
        }
    }
}
