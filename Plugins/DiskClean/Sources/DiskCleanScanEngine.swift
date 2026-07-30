import Foundation
import MacToolsPluginKit

// MARK: - 引擎接口

protocol DiskCleanScanning: Sendable {
    /// 事件流。消费方取消（`break` 出循环或 task 取消）→ `onTermination` 传导到引擎根任务 →
    /// 不再派生新的 sizing 任务（设计 §4.1）。
    ///
    /// 规则段的范围以 `DiskCleanChoice` 表达而非设计 §4.1 写的 `Set<DiskCleanCategoryID>`：
    /// 分类与 v1 的面板分组不是同构的（见 `DiskCleanChoice` 注释），按分类选择会悄悄改变扫描
    /// 覆盖面。分类仍是展示与 `categoryFinished` 的单位。
    ///
    /// P2 分段走同一个方法（设计 §10）：**只有展开来源不同**，求大小、完整性、工件铸造全部共用，
    /// 因此不存在第二条通往执行器的路。
    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error>
}

extension DiskCleanScanning {
    func scan(
        choices: Set<DiskCleanChoice>,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        scan(scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }
}

/// 阻塞式 sizing 的执行 seam（设计 §13-7 的接线点）。
///
/// 把"在常驻线程上跑 + 超时放弃 + 熔断状态"三件事收在一个协议里：引擎需要的正是这三者，
/// 而测试需要能在不启真实线程的前提下注入挂起、并伪造熔断状态来验证 limitation 派生。
protocol DiskCleanSizingExecuting: Sendable {
    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult

    var isCircuitBroken: Bool { get }
    var abandonedThreads: Int { get }
}

extension DiskCleanWorkerPool: DiskCleanSizingExecuting {}

struct DiskCleanScanEngineConfiguration: Sendable {
    /// 单项 deadline（设计 §4.2 第 3 条）。超时 → `partial([.timedOut])`。
    var itemTimeout: TimeInterval = 20
    /// 全局 deadline。到点后剩余候选一律直接标记超时，不再提交 sizing。
    var globalTimeout: TimeInterval = 300
    /// 求大小阶段并发上限。与 WorkerPool 的常驻线程数一致，多提交只会排队。
    var maximumConcurrentSizing: Int = 3
    /// 展开阶段一并上报的 `volumeSkipped` 上限。熔断时几乎每个候选都会命中，
    /// 全量上报会把 limitations 撑成几百条；`walkerCircuitBroken` 已表达同一件事。
    var maximumVolumeSkippedReports: Int = 10

    init() {}
}

// MARK: - 引擎

/// 扫描编排（设计 §4.2）。
///
/// 两阶段：**展开**（串行、快，用户 1-2 秒内看到条目）→ **求大小**（限并发、经 WorkerPool、
/// 完成即出事件）。引擎自己不碰文件系统的重活，只负责顺序、并发上限、deadline 与如实汇总。
struct DiskCleanScanEngine: DiskCleanScanning {
    let catalog: DiskCleanRuleCatalogV2
    let fileSystem: any DiskCleanFileSystemProviding
    let safetyPolicy: DiskCleanSafetyPolicy
    let sizer: any DiskCleanDirectorySizing
    let sizingExecutor: any DiskCleanSizingExecuting
    let sizeCache: DiskCleanSizeCache
    let identityProbe: any DiskCleanRootIdentityProbing
    let runningAppLock: any DiskCleanRunningAppSnapshotting
    let fullDiskAccess: any DiskCleanFullDiskAccessProbing
    /// P2 分段的展开来源（设计 §10）。
    let developerArtifactExpansion: any DiskCleanExternalExpanding
    let installerExpansion: any DiskCleanExternalExpanding
    let configuration: DiskCleanScanEngineConfiguration
    let localization: PluginLocalization
    let now: @Sendable () -> Date

    init(
        catalog: DiskCleanRuleCatalogV2 = .current,
        fileSystem: any DiskCleanFileSystemProviding = LocalDiskCleanFileSystem(),
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
        sizer: any DiskCleanDirectorySizing = DiskCleanFastWalker(),
        sizingExecutor: any DiskCleanSizingExecuting = DiskCleanWorkerPool.shared,
        sizeCache: DiskCleanSizeCache = DiskCleanSizeCache(),
        identityProbe: any DiskCleanRootIdentityProbing = DiskCleanRootIdentityProbe(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = DiskCleanRunningAppLock(),
        fullDiskAccess: any DiskCleanFullDiskAccessProbing = DiskCleanFullDiskAccessProbe.shared,
        developerArtifactExpansion: any DiskCleanExternalExpanding = DiskCleanDeveloperArtifactExpansion(),
        installerExpansion: any DiskCleanExternalExpanding = DiskCleanInstallerExpansion(),
        configuration: DiskCleanScanEngineConfiguration = DiskCleanScanEngineConfiguration(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.safetyPolicy = safetyPolicy
        self.sizer = sizer
        self.sizingExecutor = sizingExecutor
        self.sizeCache = sizeCache
        self.identityProbe = identityProbe
        self.runningAppLock = runningAppLock
        self.fullDiskAccess = fullDiskAccess
        self.developerArtifactExpansion = developerArtifactExpansion
        self.installerExpansion = installerExpansion
        self.configuration = configuration
        self.localization = localization
        self.now = now
    }

    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await run(scope: scope, forceRefresh: forceRefresh, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - 主流程

    private func run(
        scope: DiskCleanScanScope,
        forceRefresh: Bool,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async {
        let startedAt = now()
        let globalDeadline = startedAt.addingTimeInterval(configuration.globalTimeout)
        var collector = DiskCleanLimitationCollector(
            maximumVolumeSkippedReports: configuration.maximumVolumeSkippedReports
        )

        let scopedTargets = scopedTargets(for: scope)
        let lockSnapshot = await runningAppLock.makeSnapshot(
            processNames: DiskCleanRunningAppSnapshot.processNames(in: scopedTargets)
        )

        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        // 展开阶段：串行，只做展开与归属，不碰大小。
        let expansion = await expand(
            scope: scope,
            targets: scopedTargets,
            lockSnapshot: lockSnapshot,
            collector: &collector,
            continuation: continuation
        )
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        var candidates = expansion.candidates
        for candidate in candidates {
            continuation.yield(.candidateFound(candidate))
        }
        for message in Self.foundLogMessages(for: candidates, localization: localization) {
            continuation.yield(.log(message))
        }

        var pendingByCategory = Self.candidateCounts(byCategory: candidates)
        for category in expansion.scopedCategories where (pendingByCategory[category] ?? 0) == 0 {
            continuation.yield(.categoryFinished(category))
        }

        // 求大小阶段。
        let categoryByCandidateID = Dictionary(
            candidates.map { ($0.id, $0.category) },
            uniquingKeysWith: { first, _ in first }
        )
        let sizedResults = await sizeAll(
            candidates: candidates,
            forceRefresh: forceRefresh,
            globalDeadline: globalDeadline
        ) { candidateID, result in
            continuation.yield(.candidateSized(id: candidateID, result: result))
            guard let category = categoryByCandidateID[candidateID],
                  let remaining = pendingByCategory[category] else { return }
            pendingByCategory[category] = remaining - 1
            if remaining - 1 <= 0 {
                continuation.yield(.categoryFinished(category))
            }
        }

        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        for index in candidates.indices {
            guard let result = sizedResults[candidates[index].id] else { continue }
            candidates[index] = candidates[index].applying(result)
            collector.observe(sizeResult: result, path: candidates[index].path)
        }
        collector.observe(pool: sizingExecutor)

        let artifact = DiskCleanScanArtifact(
            scope: scope,
            candidates: candidates,
            reservedRootPaths: expansion.reservedRootPaths,
            limitations: collector.limitations,
            startedAt: startedAt,
            finishedAt: now()
        )
        let summary = DiskCleanScanSummary(artifact: artifact)
        for message in Self.limitationLogMessages(for: summary.limitations, localization: localization) {
            continuation.yield(.log(message))
        }
        continuation.yield(
            .log(
                DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.completed",
                        defaultValue: "扫描完成：%d 项，%d 项可清理",
                        summary.candidateCount,
                        summary.cleanableCount
                    ),
                    tone: .success
                )
            )
        )
        continuation.yield(.finished(summary))
        continuation.finish()
    }

    // MARK: - 展开阶段

    private struct ExpansionOutcome {
        var candidates: [DiskCleanCandidate] = []
        var reservedRootPaths: [String] = []
        var scopedCategories: [DiskCleanCategoryID] = []
    }

    /// 本次扫描涉及的 target。
    ///
    /// 规则段按面板分组过滤；P2 分段取对应的合成 target——它们不参与规则展开（`kind == .external`），
    /// 但仍需出现在这里，锁定快照与分类顺序都按 target 推导。
    private func scopedTargets(for scope: DiskCleanScanScope) -> [DiskCleanRuleTarget] {
        switch scope {
        case let .rules(choices):
            return catalog.targetsInDisplayOrder.filter {
                guard !$0.isExternallyDiscovered else { return false }
                return DiskCleanChoice(legacyRuleID: $0.legacyRuleID).map(choices.contains) ?? false
            }
        case .developerArtifacts:
            return catalog.targets(in: .developerArtifacts)
        case .installers:
            return catalog.targets(in: .installers)
        }
    }

    private func expand(
        scope: DiskCleanScanScope,
        targets: [DiskCleanRuleTarget],
        lockSnapshot: DiskCleanRunningAppSnapshot,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> ExpansionOutcome {
        var outcome = ExpansionOutcome()
        outcome.scopedCategories = targets.reduce(into: []) { categories, target in
            guard !categories.contains(target.category) else { return }
            categories.append(target.category)
        }

        let hits: [DiskCleanTargetHit]
        switch scope {
        case .rules:
            hits = await expandRules(
                targets: targets,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        case .developerArtifacts:
            hits = await expandExternally(
                using: developerArtifactExpansion,
                scope: scope,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        case .installers:
            hits = await expandExternally(
                using: installerExpansion,
                scope: scope,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        }

        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)
        outcome.candidates = assembler.assemble(hits: hits).map { owned in
            makeCandidate(from: owned, lockSnapshot: lockSnapshot)
        }
        return outcome
    }

    /// 专用扫描器的展开（设计 §10）。产物形状与规则展开一致，后续步骤共用。
    private func expandExternally(
        using expander: any DiskCleanExternalExpanding,
        scope: DiskCleanScanScope,
        outcome: inout ExpansionOutcome,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> [DiskCleanTargetHit] {
        let expansion = await expander.expand(
            scope: scope,
            catalog: catalog,
            localization: localization
        )
        outcome.reservedRootPaths += expansion.reservedRootPaths
        for limitation in expansion.limitations {
            collector.add(limitation)
        }
        for message in expansion.logMessages {
            continuation.yield(.log(message))
        }
        return expansion.hits
    }

    private func expandRules(
        targets: [DiskCleanRuleTarget],
        outcome: inout ExpansionOutcome,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> [DiskCleanTargetHit] {
        var hits: [DiskCleanTargetHit] = []
        var skippedByFDA: [String] = []
        let hasFullDiskAccess = fullDiskAccess.hasFullDiskAccess

        for target in targets {
            guard !Task.isCancelled else { return hits }

            // 未授权时整体跳过，绝不逐目录触发 TCC 弹窗轰炸（设计 §9）。
            if target.requiresFullDiskAccess && !hasFullDiskAccess {
                skippedByFDA.append(target.id)
                outcome.reservedRootPaths += target.expandedReservedRootPaths()
                continue
            }

            do {
                let expanded = try await expandHits(for: target)
                hits += expanded
                continuation.yield(
                    .log(
                        DiskCleanScanLogMessage(
                            text: localization.format(
                                "scanLog.expandTarget",
                                defaultValue: "展开 %@：匹配 %d 项",
                                target.id,
                                expanded.count
                            ),
                            tone: expanded.isEmpty ? .info : .success
                        )
                    )
                )
            } catch {
                // 失败的 target 记 limitation + 保留根：其子树"存在但未扫描"，
                // Planner 据此禁止删除它们的祖先。绝不阻塞整次扫描。
                collector.add(Self.failureLimitation(for: target, error: error))
                outcome.reservedRootPaths += target.expandedReservedRootPaths()
                continuation.yield(
                    .log(
                        DiskCleanScanLogMessage(
                            text: localization.format(
                                "scanLog.targetFailed",
                                defaultValue: "展开失败：%@（%@）",
                                target.id,
                                Self.reason(for: error)
                            ),
                            tone: .warning
                        )
                    )
                )
            }
        }

        if !skippedByFDA.isEmpty {
            collector.add(.fdaRestricted(skippedTargetIDs: skippedByFDA))
        }
        return hits
    }

    private func expandHits(for target: DiskCleanRuleTarget) async throws -> [DiskCleanTargetHit] {
        switch target.kind {
        case .external:
            // 合成 target 的候选由专用扫描器发现，规则展开阶段不该走到这里
            // （`scopedTargets(for:)` 已按 scope 分流）。返回空即可，绝不去猜路径。
            return []

        case let .path(globs):
            var hits: [DiskCleanTargetHit] = []
            for glob in globs {
                let specificity = DiskCleanGlobPrefix.fixedPrefix(of: glob).count
                for item in try fileSystem.expandPathPattern(glob) {
                    hits.append(
                        DiskCleanTargetHit(
                            target: target,
                            item: Self.physical(item),
                            specificity: specificity
                        )
                    )
                }
            }
            return hits

        case let .dynamic(provider):
            let items = try await provider.expand()
            let reservedRoots = target.expandedReservedRootPaths()
            return items.map { item in
                let physical = Self.physical(item)
                // 动态 target 没有 glob 可衡量特定性，用命中的保留根长度代替：
                // 保留根就是作者声明的固定前缀，语义与 glob 固定前缀一致。
                let specificity = reservedRoots
                    .filter { physical.path == $0 || physical.path.hasPrefix($0 + "/") }
                    .map(\.count)
                    .max() ?? 0
                return DiskCleanTargetHit(target: target, item: physical, specificity: specificity)
            }
        }
    }

    /// 路径一律换成物理路径（设计 §13-6）：末级保留原样，祖先解析。
    private static func physical(_ item: DiskCleanFileItem) -> DiskCleanFileItem {
        let physicalPath = DiskCleanPhysicalPath.resolve(item.path)
        guard physicalPath != item.path else { return item }
        return DiskCleanFileItem(
            path: physicalPath,
            isDirectory: item.isDirectory,
            isSymlink: item.isSymlink,
            resolvedSymlinkTarget: item.resolvedSymlinkTarget
        )
    }

    private func makeCandidate(
        from owned: DiskCleanOwnedPath,
        lockSnapshot: DiskCleanRunningAppSnapshot
    ) -> DiskCleanCandidate {
        let target = owned.target
        let safety: DiskCleanSafetyStatus
        if let processName = lockSnapshot.lockingProcessName(for: target) {
            safety = .inUse(processName: processName)
        } else {
            safety = safetyPolicy.safetyStatus(
                for: owned.item.path,
                isSymlink: owned.item.isSymlink,
                resolvedSymlinkTarget: owned.item.resolvedSymlinkTarget
            )
        }

        return DiskCleanCandidate(
            id: DiskCleanCandidate.makeID(targetID: target.id, path: owned.item.path),
            targetID: target.id,
            legacyRuleID: target.legacyRuleID,
            category: target.category,
            path: owned.item.path,
            // 展开来源没给覆盖值就用 target 风险（规则候选恒走这条）。
            risk: owned.facts.risk ?? target.risk,
            safety: safety,
            notes: owned.facts.notes,
            sizeResult: nil
        )
    }

    // MARK: - 求大小阶段

    private func sizeAll(
        candidates: [DiskCleanCandidate],
        forceRefresh: Bool,
        globalDeadline: Date,
        onResult: (DiskCleanCandidate.ID, DiskCleanSizeResult) -> Void
    ) async -> [DiskCleanCandidate.ID: DiskCleanSizeResult] {
        guard !candidates.isEmpty else { return [:] }

        let cachingSizer = DiskCleanCachingSizer(
            base: sizer,
            cache: sizeCache,
            identityProbe: identityProbe,
            forceRefresh: forceRefresh
        )
        var results: [DiskCleanCandidate.ID: DiskCleanSizeResult] = [:]
        results.reserveCapacity(candidates.count)

        await withTaskGroup(of: (DiskCleanCandidate.ID, DiskCleanSizeResult).self) { group in
            var iterator = candidates.makeIterator()
            var inFlight = 0

            // 取消后**不再派生**新任务：已在飞的任务由 WorkerPool 的取消标志收尾。
            func submitNext() -> Bool {
                guard !Task.isCancelled, let candidate = iterator.next() else { return false }
                group.addTask {
                    (candidate.id, await size(candidate, using: cachingSizer, globalDeadline: globalDeadline))
                }
                inFlight += 1
                return true
            }

            while inFlight < max(configuration.maximumConcurrentSizing, 1), submitNext() {}

            while let (candidateID, result) = await group.next() {
                inFlight -= 1
                results[candidateID] = result
                onResult(candidateID, result)
                _ = submitNext()
            }
        }

        return results
    }

    private func size(
        _ candidate: DiskCleanCandidate,
        using sizer: any DiskCleanDirectorySizing,
        globalDeadline: Date
    ) async -> DiskCleanSizeResult {
        let startedAt = now()
        // 全局 deadline 已过：直接如实标记超时。不提交任务，但仍要出事件，
        // 否则 UI 会永远停在"计算中"。
        guard startedAt < globalDeadline else {
            return .unavailable(reasons: [.timedOut], observedAt: startedAt)
        }

        let itemDeadline = min(
            startedAt.addingTimeInterval(configuration.itemTimeout),
            globalDeadline
        )
        return await sizingExecutor.size(
            ofItemAt: candidate.path,
            using: sizer,
            deadline: itemDeadline
        )
    }

    // MARK: - 日志与 limitation 文案

    private static func candidateCounts(
        byCategory candidates: [DiskCleanCandidate]
    ) -> [DiskCleanCategoryID: Int] {
        candidates.reduce(into: [:]) { counts, candidate in
            counts[candidate.category, default: 0] += 1
        }
    }

    private static func failureLimitation(
        for target: DiskCleanRuleTarget,
        error: Error
    ) -> DiskCleanScanLimitation {
        target.isDynamic
            ? .dynamicRuleFailed(targetID: target.id, reason: reason(for: error))
            : .targetExpansionFailed(targetID: target.id, reason: reason(for: error))
    }

    private static func reason(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    /// 只为**不可清理**的候选出日志：可清理项在候选列表里一目了然，
    /// 需要解释的恰恰是"为什么这条不能删"。
    private static func foundLogMessages(
        for candidates: [DiskCleanCandidate],
        localization: PluginLocalization
    ) -> [DiskCleanScanLogMessage] {
        candidates.compactMap { candidate in
            switch candidate.safety {
            case .allowed:
                return nil
            case let .whitelisted(rule):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.whitelisted",
                        defaultValue: "白名单保护：%@（%@）",
                        candidate.path,
                        rule
                    ),
                    tone: .warning
                )
            case let .protected(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.protected",
                        defaultValue: "敏感数据保护：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .invalid(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.invalid",
                        defaultValue: "路径安全保护：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .requiresAdmin(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.requiresAdmin",
                        defaultValue: "需要管理员权限：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .inUse(processName):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.inUse",
                        defaultValue: "正在使用(%@)：%@",
                        processName,
                        candidate.path
                    ),
                    tone: .warning
                )
            }
        }
    }

    private static func limitationLogMessages(
        for limitations: [DiskCleanScanLimitation],
        localization: PluginLocalization
    ) -> [DiskCleanScanLogMessage] {
        limitations.map { limitation in
            switch limitation {
            case let .fdaRestricted(skippedTargetIDs):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.fda",
                        defaultValue: "未开启完全磁盘访问，已跳过 %d 项规则",
                        skippedTargetIDs.count
                    ),
                    tone: .warning
                )
            case let .dynamicRuleFailed(targetID, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.dynamicFailed",
                        defaultValue: "动态规则失败：%@（%@）",
                        targetID,
                        reason
                    ),
                    tone: .warning
                )
            case let .targetExpansionFailed(targetID, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.expansionFailed",
                        defaultValue: "规则展开失败：%@（%@）",
                        targetID,
                        reason
                    ),
                    tone: .warning
                )
            case let .volumeSkipped(path):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.volumeSkipped",
                        defaultValue: "已跳过不支持的卷：%@",
                        path
                    ),
                    tone: .warning
                )
            case let .scanRootUnreadable(path, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.scanRootUnreadable",
                        defaultValue: "无法读取 %@（%@）",
                        path,
                        DiskCleanFormat.partialReasons([reason], localization: localization)
                    ),
                    tone: .warning
                )
            case .walkerCircuitBroken:
                return DiskCleanScanLogMessage(
                    text: localization.string(
                        "scanLog.limitation.circuitBroken",
                        defaultValue: "扫描引擎已降级，重启应用恢复"
                    ),
                    tone: .error
                )
            case let .threadsAbandoned(count):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.threadsAbandoned",
                        defaultValue: "%d 个扫描线程无响应已被放弃",
                        count
                    ),
                    tone: .warning
                )
            }
        }
    }
}

// MARK: - limitation 收集

/// 顺序稳定、去重、上报量有界的 limitation 收集器。
struct DiskCleanLimitationCollector {
    private(set) var limitations: [DiskCleanScanLimitation] = []
    private var volumeSkippedPaths: Set<String> = []
    private let maximumVolumeSkippedReports: Int

    init(maximumVolumeSkippedReports: Int) {
        self.maximumVolumeSkippedReports = max(maximumVolumeSkippedReports, 0)
    }

    mutating func add(_ limitation: DiskCleanScanLimitation) {
        guard !limitations.contains(limitation) else { return }
        limitations.append(limitation)
    }

    /// 从 sizing 结果派生卷级 limitation。
    mutating func observe(sizeResult: DiskCleanSizeResult, path: String) {
        guard sizeResult.completeness.partialReasons.contains(.unsupportedVolume) else { return }
        guard volumeSkippedPaths.count < maximumVolumeSkippedReports else { return }
        guard volumeSkippedPaths.insert(path).inserted else { return }
        add(.volumeSkipped(path: path))
    }

    /// 熔断与线程放弃从 WorkerPool 的**进程级**状态派生（设计 §4.5、§13-7）。
    /// 不依赖"本次扫描恰好产生了某种候选"——上一次扫描烧掉的预算同样必须被看见。
    mutating func observe(pool: any DiskCleanSizingExecuting) {
        if pool.isCircuitBroken {
            add(.walkerCircuitBroken)
        }
        let abandoned = pool.abandonedThreads
        if abandoned > 0 {
            add(.threadsAbandoned(count: abandoned))
        }
    }
}

// MARK: - 所有权归属与祖先分解

/// 展开阶段的一条原始命中。
struct DiskCleanTargetHit: Sendable {
    let target: DiskCleanRuleTarget
    let item: DiskCleanFileItem
    /// 命中它的 glob（动态 target 用保留根）的固定前缀长度，越长越特定。
    /// P2 合成 target 无 glob 可衡量，恒为 0——同一路径不会被两个合成 target 同时命中。
    let specificity: Int
    /// 展开阶段才知道的候选属性（P2 的 git 状态、安装包年龄等）。规则命中一律 `.inherited`。
    let facts: DiskCleanCandidateFacts

    init(
        target: DiskCleanRuleTarget,
        item: DiskCleanFileItem,
        specificity: Int,
        facts: DiskCleanCandidateFacts = .inherited
    ) {
        self.target = target
        self.item = item
        self.specificity = specificity
        self.facts = facts
    }
}

struct DiskCleanOwnedPath: Sendable {
    let target: DiskCleanRuleTarget
    let item: DiskCleanFileItem
    /// 祖先分解出的子项继承分解源的 facts——它们是同一条命中的碎片，风险与附注理应一致。
    let facts: DiskCleanCandidateFacts

    init(
        target: DiskCleanRuleTarget,
        item: DiskCleanFileItem,
        facts: DiskCleanCandidateFacts = .inherited
    ) {
        self.target = target
        self.item = item
        self.facts = facts
    }
}

/// 所有权归属与祖先分解（设计 §5.3）。纯函数式：输入命中集，输出最终归属表。
struct DiskCleanCandidateAssembler: Sendable {
    /// 分解递归深度上限。递归只会沿"存在后代候选"的分支下潜，深度天然有界；
    /// 上限只是对病态输入（超深路径）的兜底。
    static let maximumDecompositionDepth = 64

    let fileSystem: any DiskCleanFileSystemProviding

    func assemble(hits: [DiskCleanTargetHit]) -> [DiskCleanOwnedPath] {
        let owners = Self.resolveOwnership(hits: hits)
        let paths = owners.keys.sorted()
        var results: [DiskCleanOwnedPath] = []
        let pathSet = Set(paths)

        for path in paths {
            guard let hit = owners[path] else { continue }
            // 无后代候选 → 保持独立身份，原样收下。
            guard Self.hasStrictDescendant(of: path, in: paths) else {
                results.append(
                    DiskCleanOwnedPath(target: hit.target, item: hit.item, facts: hit.facts)
                )
                continue
            }
            results += decompose(
                path: path,
                target: hit.target,
                facts: hit.facts,
                allPaths: pathSet,
                sortedPaths: paths,
                depth: 0
            )
        }

        return results.sorted { $0.item.path < $1.item.path }
    }

    /// 同一路径被多 target 命中 → 归属最特定者：glob 固定前缀最长，并列取更高风险
    /// （宁严勿宽），仍并列时按 target id 取定（保证结果可测、与遍历顺序无关）。
    static func resolveOwnership(hits: [DiskCleanTargetHit]) -> [String: DiskCleanTargetHit] {
        var owners: [String: DiskCleanTargetHit] = [:]
        for hit in hits {
            guard let incumbent = owners[hit.item.path] else {
                owners[hit.item.path] = hit
                continue
            }
            if isMoreSpecific(hit, than: incumbent) {
                owners[hit.item.path] = hit
            }
        }
        return owners
    }

    private static func isMoreSpecific(
        _ candidate: DiskCleanTargetHit,
        than incumbent: DiskCleanTargetHit
    ) -> Bool {
        if candidate.specificity != incumbent.specificity {
            return candidate.specificity > incumbent.specificity
        }
        if candidate.target.risk != incumbent.target.risk {
            return candidate.target.risk > incumbent.target.risk
        }
        return candidate.target.id < incumbent.target.id
    }

    /// 祖先分解：A 是 B 的祖先 → A 换成自己的直接子项（继承 A 的 target 与风险），
    /// 递归至不含任何其它候选；B 保持独立身份（自己的风险、锁定、默认勾选）。
    ///
    /// 目录列不出来时**整块放弃 A**：保留 A 会连带删掉 B 的子树，
    /// 那等于抹掉 B 独立的风险判定与勾选状态。宁少清理，不越权。
    private func decompose(
        path: String,
        target: DiskCleanRuleTarget,
        facts: DiskCleanCandidateFacts,
        allPaths: Set<String>,
        sortedPaths: [String],
        depth: Int
    ) -> [DiskCleanOwnedPath] {
        guard depth < Self.maximumDecompositionDepth else { return [] }
        guard let children = try? fileSystem.directChildren(of: path) else { return [] }

        var results: [DiskCleanOwnedPath] = []
        for child in children {
            // 子项本身就是候选 → 它有自己的身份，不吞并。
            if allPaths.contains(child.path) {
                continue
            }
            if Self.hasStrictDescendant(of: child.path, in: sortedPaths) {
                results += decompose(
                    path: child.path,
                    target: target,
                    facts: facts,
                    allPaths: allPaths,
                    sortedPaths: sortedPaths,
                    depth: depth + 1
                )
                continue
            }
            results.append(DiskCleanOwnedPath(target: target, item: child, facts: facts))
        }
        return results
    }

    /// `sortedPaths` 已排序，故严格后代必然紧随其后连续出现。
    static func hasStrictDescendant(of path: String, in sortedPaths: [String]) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard let index = sortedPaths.firstIndex(where: { $0 > path }) else { return false }
        return sortedPaths[index].hasPrefix(prefix)
    }
}
