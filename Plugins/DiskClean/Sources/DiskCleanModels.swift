import Foundation
import MacToolsPluginKit

// MARK: - 面板分组

/// 菜单栏与详情页的三个扫描范围分组。
///
/// 规则 v2 已按 `DiskCleanCategoryID` 分成十类，但面板仍保留 v1 的三个分组：分类不能承担
/// "扫描范围"这个职责——`aiTools` 同时收纳 `cache.ai-assistants` 与 `developer.ai-agent-old-versions`，
/// `developer` 分类里还有一个 legacy 为 `browser.service-worker` 的 target。范围一律按
/// `legacyRuleID` 前缀判定，扫描覆盖面因此与 v1 逐条等价（M5 再引入按分类选择）。
enum DiskCleanChoice: String, CaseIterable, Identifiable, Equatable, Sendable {
    case cache
    case developer
    case browser

    var id: String { rawValue }

    /// v1 规则 id 前缀 → 面板分组。这是 v1/v2 扫描范围等价性的唯一判定点。
    init?(legacyRuleID: String) {
        switch legacyRuleID.prefix(while: { $0 != "." }) {
        case "cache":
            self = .cache
        case "developer":
            self = .developer
        case "browser":
            self = .browser
        default:
            return nil
        }
    }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .cache:
            return localization.string("choice.cache.title", defaultValue: "缓存清理")
        case .developer:
            return localization.string("choice.developer.title", defaultValue: "开发者缓存清理")
        case .browser:
            return localization.string("choice.browser.title", defaultValue: "浏览器缓存清理")
        }
    }
}

// MARK: - 扫描范围

/// 一次扫描的范围（设计 §10）。
///
/// 三个取值对应详情页的三个独立分段。它们共用**同一条管线**——同一个引擎、同一套 sizing、
/// 同一个 Planner、同一个执行器——区别只在候选从哪里来：规则目录展开，还是专用扫描器发现。
/// 把这个区别收在一个枚举里，Controller 因此不需要为 P2 再写一套状态机。
enum DiskCleanScanScope: Equatable, Sendable {
    /// 规则目录展开（v1 的三个面板分组）。
    case rules(choices: Set<DiskCleanChoice>)
    /// 开发产物清扫（设计 §10.1）。`roots` 是用户配置的扫描根，已规范化为物理路径。
    case developerArtifacts(roots: [String])
    /// 残留安装包（设计 §10.2）。范围固定为 `~/Downloads` 顶层，无参数。
    case installers

    /// 分段身份（不含参数）。用于选择 UI 分段、日志前缀这类"只关心是哪一段"的地方。
    var section: DiskCleanScanSection {
        switch self {
        case .rules:
            return .rules
        case .developerArtifacts:
            return .developerArtifacts
        case .installers:
            return .installers
        }
    }

    /// 范围为空 = 没有可扫的东西，扫描入口应当禁用。
    /// 规则段是"一个分组都没勾"，开发产物段是"还没添加任何文件夹"——两者都要引导而不是空转。
    var isEmpty: Bool {
        switch self {
        case let .rules(choices):
            return choices.isEmpty
        case let .developerArtifacts(roots):
            return roots.isEmpty
        case .installers:
            return false
        }
    }

    /// 规则段的分组集合。其余分段没有分组概念，返回空集。
    var choices: Set<DiskCleanChoice> {
        guard case let .rules(choices) = self else { return [] }
        return choices
    }

    var developerArtifactRoots: [String] {
        guard case let .developerArtifacts(roots) = self else { return [] }
        return roots
    }
}

enum DiskCleanScanSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case rules
    case developerArtifacts
    case installers

    var id: String { rawValue }
}

enum DiskCleanRisk: Equatable, Sendable {
    case low
    case medium
    case high
}

enum DiskCleanSafetyStatus: Equatable, Sendable {
    case allowed
    case whitelisted(rule: String)
    case protected(reason: String)
    case invalid(reason: String)
    case requiresAdmin(reason: String)
    case inUse(processName: String)

    var isCleanable: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }
}

// MARK: - 扫描日志

enum DiskCleanScanLogTone: Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

struct DiskCleanScanLogMessage: Equatable, Sendable {
    let text: String
    let tone: DiskCleanScanLogTone
}

struct DiskCleanScanLogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let tone: DiskCleanScanLogTone
}

// MARK: - 扫描级 limitations

/// 一次扫描的完整性缺口（设计 §4.5）。
///
/// 菜单栏"（受限）"与详情页横幅一律从这里派生，**不依赖"恰好存在 permissionDenied 候选"**：
/// 被整体跳过的 target 根本不会产生候选，只有显式 limitation 能把这件事说出来。
enum DiskCleanScanLimitation: Equatable, Sendable {
    /// 未授予完全磁盘访问，整体跳过的 target。
    case fdaRestricted(skippedTargetIDs: [String])
    /// 动态 provider 失败（子进程超时、输出畸形）。
    case dynamicRuleFailed(targetID: String, reason: String)
    /// glob 展开失败。设计 §4.5 未列此项：路径类 target 的固定前缀同样可能因 EIO/EACCES
    /// 展开失败，让整次扫描抛错比降级更糟，而复用 `dynamicRuleFailed` 会谎报原因。
    case targetExpansionFailed(targetID: String, reason: String)
    /// 非本地卷 / 熔断后未 sizing 的候选路径。
    case volumeSkipped(path: String)
    /// P2 分段的扫描根整个打不开（设计 §10）：目录已删除、TCC 拒绝、或不是目录。
    ///
    /// **与"扫了但没有候选"必须分开**：`~/Downloads` 被 TCC 拒绝时里面可能躺着几十 GB 安装包，
    /// 显示"没有可清理项"是在骗用户。`reason` 决定引导文案走授权还是走"文件夹已失效"。
    case scanRootUnreadable(path: String, reason: DiskCleanScanCompleteness.PartialReason)
    /// WorkerPool 放弃预算耗尽，本进程不再执行任何 sizing。
    case walkerCircuitBroken
    /// 累计被放弃的线程数。
    case threadsAbandoned(count: Int)
}

// MARK: - 候选附注

/// 候选自身事实产生的提示（设计 §10）。
///
/// 与 `safety` 的分工："能不能删"归 `safety`，"删之前该知道什么"归这里。note **不影响可清理性**，
/// 只驱动徽标与默认勾选——默认勾选走的是 `risk`，由展开来源按同一批事实给出（见
/// `DiskCleanCandidateFacts`）。两者刻意分开：让徽标去决定能否删除，等于在 `isCleanable`
/// 之外开第二个判定点。
enum DiskCleanCandidateNote: Equatable, Sendable {
    /// 所在 git 仓库有未提交改动 / 未推送提交 / 检查失败（设计 §10.1，失败按"有改动"处理）。
    /// 携带结构化原因而不是成品文案：本类型会进工件，文案属于视图层。
    case repositoryHasChanges(repositoryPath: String, reason: DiskCleanPurgeGitState.DirtyReason)
    /// 所属工程根与命中的工程标记文件。`marker == nil` 表示无条件命中（`__pycache__`）。
    case developerProject(path: String, marker: String?)
    /// `.zip` 未必是安装包（设计 §10.2）。
    case mayNotBeInstaller
    /// 下载不足 7 天，可能还没装。
    case recentlyDownloaded(modifiedAt: Date)
}

/// 展开阶段才知道的候选属性。
///
/// 规则 target 的风险写死在目录里，但 P2 合成 target 做不到：同一个 `purge.artifacts` 下，
/// 仓库干净的 `node_modules` 该默认勾选、有未提交改动的不该，而"仓库脏不脏"要跑完 git 才知道。
/// 因此风险在这里允许被展开来源覆盖——**这是 `candidate.risk != target.risk` 的唯一来源**，
/// 且只影响默认勾选（Planner 与执行器都不看 risk）。
struct DiskCleanCandidateFacts: Equatable, Sendable {
    /// nil = 沿用 target 风险。
    var risk: DiskCleanRisk?
    var notes: [DiskCleanCandidateNote] = []

    static let inherited = DiskCleanCandidateFacts()
}

// MARK: - 候选

/// 一个清理候选。
///
/// `sizeResult == nil` 表示"已发现、大小未知"——展开阶段先流式出条目让用户 1-2 秒内看到内容，
/// 求大小随后异步补齐（设计 §4.2）。未定大小与非 complete 的候选一律不可清理（§3.1 不变量）。
struct DiskCleanCandidate: Identifiable, Equatable, Sendable {
    /// `targetID::physicalPath`。同一路径只会归属一个 target（§5.3 所有权归属）。
    let id: String
    let targetID: String
    /// v1 规则 id。审计、白名单迁移与面板分组都依赖它。
    let legacyRuleID: String
    let category: DiskCleanCategoryID
    /// **物理路径**（不含符号链接祖先，见设计 §13-6）。
    let path: String
    /// 默认勾选策略只看这里。规则候选取自 target；P2 候选可被展开来源覆盖
    /// （见 `DiskCleanCandidateFacts`）。
    let risk: DiskCleanRisk
    let safety: DiskCleanSafetyStatus
    /// 展示用附注。不参与可清理性判定。
    let notes: [DiskCleanCandidateNote]
    /// 求大小结果。nil = 尚未求大小。
    let sizeResult: DiskCleanSizeResult?

    init(
        id: String,
        targetID: String,
        legacyRuleID: String,
        category: DiskCleanCategoryID,
        path: String,
        risk: DiskCleanRisk,
        safety: DiskCleanSafetyStatus,
        notes: [DiskCleanCandidateNote] = [],
        sizeResult: DiskCleanSizeResult? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.legacyRuleID = legacyRuleID
        self.category = category
        self.path = path
        self.risk = risk
        self.safety = safety
        self.notes = notes
        self.sizeResult = sizeResult
    }

    static func makeID(targetID: String, path: String) -> String {
        "\(targetID)::\(path)"
    }

    /// 面板分组。legacyRuleID 无法识别时归入缓存组——绝不静默丢弃候选。
    var choice: DiskCleanChoice {
        DiskCleanChoice(legacyRuleID: legacyRuleID) ?? .cache
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    /// 估算逻辑大小。未定大小时为 0，UI 应据 `sizeResult == nil` 显示"计算中"而不是"0 字节"。
    var estimatedBytes: Int64 {
        max(sizeResult?.estimatedBytes ?? 0, 0)
    }

    /// 是否可清理。
    ///
    /// 设计 §3.1 的核心不变量落在这里：安全状态放行**且**大小已求出且 completeness 为 complete。
    /// `crossedMountPoint` 无需单列——它必然出现在 `partial` 的原因集合里，已被 `isComplete` 拦下。
    var isCleanable: Bool {
        guard safety.isCleanable, let sizeResult else { return false }
        return sizeResult.completeness.isComplete && sizeResult.rootIdentity != nil
    }

    /// 观测时刻。过期门（§4.4）取全体选中项的最小值。
    var observedAt: Date? {
        sizeResult?.observedAt
    }

    func applying(_ sizeResult: DiskCleanSizeResult) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: targetID,
            legacyRuleID: legacyRuleID,
            category: category,
            path: path,
            risk: risk,
            safety: safety,
            notes: notes,
            sizeResult: sizeResult
        )
    }
}

// MARK: - 结果新鲜度

/// 结果过期门（设计 §4.4）。
///
/// **定位声明：这是误操作防护**（防"扫完放半天再点清理"），**不构成 TOCTOU 防护**——
/// 执行时的防线是身份验证与冻结原语（§7）。任何文档、注释、用户文案都不得声称此门
/// "防止删除未审查内容"。
enum DiskCleanScanFreshness {
    /// 过期窗口。缓存 TTL 必须严格小于此值（见 `DiskCleanSizeCache.timeToLive`）。
    static let window: TimeInterval = 300

    static func deadline(minObservedAt: Date) -> Date {
        minObservedAt.addingTimeInterval(window)
    }
}

// MARK: - 扫描事件与工件

enum DiskCleanScanEvent: Sendable {
    case log(DiskCleanScanLogMessage)
    /// 大小未知，不可勾选。
    case candidateFound(DiskCleanCandidate)
    case candidateSized(id: DiskCleanCandidate.ID, result: DiskCleanSizeResult)
    case categoryFinished(DiskCleanCategoryID)
    case finished(DiskCleanScanSummary)
}

/// 一次扫描的不可变工件，是 M4 `DiskCleanPlanner.makePlan` 的**唯一**输入（设计 §6.1）。
///
/// Planner 从这里推导排除集与保留前缀，Controller 只能递交 `selectedIDs` 做减法，
/// 因此无法伪造证据、也无法漏传保留前缀。
struct DiskCleanScanArtifact: Equatable, Sendable {
    let scope: DiskCleanScanScope
    /// 全体候选（含不可清理项），携带最终 sizeResult。
    let candidates: [DiskCleanCandidate]
    /// 被跳过 / 失败 target 的保留根（已展开 `~`）。
    ///
    /// 这些子树"存在但未扫描"，Planner 必须禁止删除它们的祖先（§6.1 第 3 条）。
    let reservedRootPaths: [String]
    let limitations: [DiskCleanScanLimitation]
    let startedAt: Date
    let finishedAt: Date

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter(\.isCleanable)
    }

    /// 不可清理候选的路径。
    ///
    /// **不是** `Planner` 的排除集：后者是"全体未入计划的候选"，随选中集变化，由 `makePlan`
    /// 自行推导（§6.1 第 2 条明确不接受调用方传入）。本属性是与选中集无关的那一部分——
    /// 锁定 / 白名单 / 保护 / partial / 未求大小——扫描引擎测试据此断言"不完整的候选确实进了排除集"。
    var exclusionPaths: [String] {
        candidates.filter { !$0.isCleanable }.map(\.path)
    }
}

/// 扫描汇总（设计 §4.5）。统计口径一律从工件派生，避免两份数字打架。
struct DiskCleanScanSummary: Equatable, Sendable {
    let artifact: DiskCleanScanArtifact

    var limitations: [DiskCleanScanLimitation] { artifact.limitations }
    var candidateCount: Int { artifact.candidates.count }
    var cleanableCount: Int { artifact.cleanableCandidates.count }
    var cleanableEstimatedBytes: Int64 {
        artifact.cleanableCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }
}

// MARK: - 控制器持有的扫描结果投影

/// 扫描结果的 UI 投影。扫描进行中即存在（`artifact == nil`），完成后带上工件。
struct DiskCleanScanResult: Equatable, Sendable {
    /// 产出本结果的扫描范围。与当前范围不等即"结果已陈旧"（`isResultStale`）——
    /// 规则段是改了分组，开发产物段是加减了扫描根，两者语义相同。
    let scope: DiskCleanScanScope
    let candidates: [DiskCleanCandidate]
    let scannedAt: Date
    let limitations: [DiskCleanScanLimitation]
    /// 仅扫描完成后存在。清理入口只接受非 nil 的工件。
    let artifact: DiskCleanScanArtifact?

    init(
        scope: DiskCleanScanScope,
        candidates: [DiskCleanCandidate],
        scannedAt: Date,
        limitations: [DiskCleanScanLimitation] = [],
        artifact: DiskCleanScanArtifact? = nil
    ) {
        self.scope = scope
        self.candidates = candidates
        self.scannedAt = scannedAt
        self.limitations = limitations
        self.artifact = artifact
    }

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter(\.isCleanable)
    }

    var cleanableSizeBytes: Int64 {
        cleanableCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }

    var isLimited: Bool {
        !limitations.isEmpty
    }

    /// 过期门时刻：全体可清理候选的最早观测时刻 + 300s。无可清理候选时无需过期。
    var expiryDeadline: Date? {
        cleanableCandidates
            .compactMap(\.observedAt)
            .min()
            .map(DiskCleanScanFreshness.deadline(minObservedAt:))
    }
}
