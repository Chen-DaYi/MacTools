import Foundation
import MacToolsPluginKit

// MARK: - 展开产物

/// 一次非规则展开的产物（设计 §10）。
///
/// 形状刻意与规则展开阶段的产出对齐——命中 + 保留根 + limitation + 日志——这样引擎后续的
/// 归属、安全判定、求大小、铸造工件全部照原样跑一遍，P2 候选不存在"绕过某一步"的可能。
struct DiskCleanExternalExpansion: Sendable {
    var hits: [DiskCleanTargetHit] = []
    var reservedRootPaths: [String] = []
    var limitations: [DiskCleanScanLimitation] = []
    var logMessages: [DiskCleanScanLogMessage] = []

    init() {}
}

/// 专用扫描器 → 统一管线的适配 seam。
///
/// 引擎只认这个协议，因此测试可以在不碰文件系统的前提下把任意候选送进完整管线
/// （sizing → 完整性 → 工件 → Planner → 执行器），验证的是管线而不是扫描器。
protocol DiskCleanExternalExpanding: Sendable {
    /// `catalog` 用于按 targetID 取回合成 target。目录里没有的 targetID 一律丢弃并记日志——
    /// 挂不上 target 的候选后面必然在 `makePlan` 处被拒，早丢早说清楚。
    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion
}

// MARK: - 开发产物

/// `DiskCleanPurgeScanner` → 统一管线（设计 §10.1）。
struct DiskCleanDeveloperArtifactExpansion: DiskCleanExternalExpanding {
    private let scanner: DiskCleanPurgeScanner

    init(scanner: DiskCleanPurgeScanner = DiskCleanPurgeScanner()) {
        self.scanner = scanner
    }

    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion {
        var expansion = DiskCleanExternalExpansion()
        let roots = scope.developerArtifactRoots
        guard !roots.isEmpty else { return expansion }

        // **全体已配置的根都进保留集**，与遍历是否成功无关。
        //
        // 语义："根本身不是删除对象，且根下未被候选覆盖的部分从未经过审查"。祖先断言因此
        // 拒绝任何以某个根为后代的计划路径（例如 `~` 或根的父目录），而根**内部**的候选
        // 不受影响——它们是根的后代，不是祖先。深度上限 6 与命中即剪枝留下的未扫区域，
        // 同样被这条覆盖。
        expansion.reservedRootPaths = roots

        let result = await scanner.scan(roots: roots)
        for report in result.reports {
            switch report.status {
            case let .unreadable(reason):
                // 根整个打不开：与"扫过但没有候选"必须分开，否则用户看到的是一个骗人的空列表。
                expansion.limitations.append(
                    .scanRootUnreadable(path: report.root, reason: reason)
                )

            case let .traversed(completeness):
                // 部分子树被跳过只影响"发现得全不全"，不影响已发现候选的可删性（根已在保留集里）。
                // 因此只记日志，不升级成 limitation——列表本身就摆在用户眼前，而根不可读时
                // 用户没有任何别的信号。
                guard case let .partial(reasons) = completeness else { break }
                expansion.logMessages.append(
                    DiskCleanScanLogMessage(
                        text: localization.format(
                            "scanLog.purge.partialRoot",
                            defaultValue: "%@ 有子目录未能读取（%@），可能漏报部分产物",
                            report.root,
                            DiskCleanFormat.partialReasons(reasons, localization: localization)
                        ),
                        tone: .warning
                    )
                )
            }

            for candidate in report.candidates {
                guard let target = catalog.target(id: candidate.kind.targetID) else {
                    expansion.logMessages.append(Self.missingTargetLog(candidate.kind.targetID, localization: localization))
                    continue
                }
                expansion.hits.append(
                    DiskCleanTargetHit(
                        target: target,
                        item: DiskCleanFileItem(
                            path: candidate.path,
                            isDirectory: true,
                            isSymlink: false,
                            resolvedSymlinkTarget: nil
                        ),
                        specificity: 0,
                        facts: Self.facts(for: candidate)
                    )
                )
            }
        }

        return expansion
    }

    /// 仓库脏（含检查失败）→ 保持 target 的 medium，不默认勾选；其余降到 low 默认勾选。
    static func facts(for candidate: DiskCleanPurgeCandidate) -> DiskCleanCandidateFacts {
        var notes: [DiskCleanCandidateNote] = [
            .developerProject(path: candidate.projectPath, marker: candidate.projectMarker)
        ]
        if case let .dirty(repositoryPath, reason) = candidate.gitState {
            notes.append(.repositoryHasChanges(repositoryPath: repositoryPath, reason: reason))
        }
        return DiskCleanCandidateFacts(
            risk: candidate.isSelectedByDefault ? .low : nil,
            notes: notes
        )
    }

    private static func missingTargetLog(
        _ targetID: String,
        localization: PluginLocalization
    ) -> DiskCleanScanLogMessage {
        DiskCleanScanLogMessage(
            text: localization.format(
                "scanLog.missingTarget",
                defaultValue: "规则目录缺少 target %@，已跳过对应候选",
                targetID
            ),
            tone: .error
        )
    }
}

// MARK: - 残留安装包

/// `DiskCleanInstallerScanner` → 统一管线（设计 §10.2）。
struct DiskCleanInstallerExpansion: DiskCleanExternalExpanding {
    private let scanner: DiskCleanInstallerScanner

    init(scanner: DiskCleanInstallerScanner = DiskCleanInstallerScanner()) {
        self.scanner = scanner
    }

    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion {
        var expansion = DiskCleanExternalExpansion()
        // 范围固定，保留根取自合成 target 自己的声明，与规则 target 同一来源。
        // 五个 target 声明的是同一个 `~/Downloads`，去重后只留一条。
        var seenRoots: Set<String> = []
        expansion.reservedRootPaths = DiskCleanInstallerKind.allCases
            .compactMap { catalog.target(id: $0.targetID) }
            .flatMap { $0.expandedReservedRootPaths() }
            .filter { seenRoots.insert($0).inserted }

        switch await scanInBackground() {
        case let .denied(path):
            // TCC 拒绝（`~/Downloads` 属于会弹窗的那一类）。目录里可能躺着几十 GB，
            // 报"没有可清理项"是在骗用户。
            expansion.limitations.append(.scanRootUnreadable(path: path, reason: .permissionDenied))

        case let .unavailable(path, reason):
            expansion.limitations.append(.scanRootUnreadable(path: path, reason: reason))

        case let .scanned(candidates):
            for candidate in candidates {
                guard let target = catalog.target(id: candidate.kind.targetID) else {
                    expansion.logMessages.append(
                        DiskCleanScanLogMessage(
                            text: localization.format(
                                "scanLog.missingTarget",
                                defaultValue: "规则目录缺少 target %@，已跳过对应候选",
                                candidate.kind.targetID
                            ),
                            tone: .error
                        )
                    )
                    continue
                }
                expansion.hits.append(
                    DiskCleanTargetHit(
                        target: target,
                        item: DiskCleanFileItem(
                            path: candidate.path,
                            isDirectory: false,
                            isSymlink: false,
                            resolvedSymlinkTarget: nil
                        ),
                        specificity: 0,
                        facts: Self.facts(for: candidate)
                    )
                )
            }
        }

        return expansion
    }

    /// `.zip` 与"下载不足 7 天"都保持 target 的 medium；其余降到 low 默认勾选。
    static func facts(for candidate: DiskCleanInstallerCandidate) -> DiskCleanCandidateFacts {
        var notes: [DiskCleanCandidateNote] = []
        switch candidate.note {
        case .mayNotBeInstaller:
            notes.append(.mayNotBeInstaller)
        case .recentlyModified:
            notes.append(.recentlyDownloaded(modifiedAt: candidate.modifiedAt))
        case nil:
            break
        }
        return DiskCleanCandidateFacts(
            risk: candidate.isSelectedByDefault ? .low : nil,
            notes: notes
        )
    }

    /// 扫描是阻塞的（一次顶层 `readdir` + 逐条 `fstatat`），不能占用 Swift 并发的协作线程池。
    /// 同一次调用也可能触发 `~/Downloads` 的 TCC 弹窗，那更不该发生在协作线程上。
    private func scanInBackground() async -> DiskCleanInstallerScanOutcome {
        let scanner = self.scanner
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: scanner.scan())
            }
        }
    }
}
