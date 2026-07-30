import Foundation
import MacToolsPluginKit

// MARK: - 风险排序

/// 风险等级可比较，供分类展示排序（低 → 高）与"动态规则至少 medium"一类断言使用。
extension DiskCleanRisk: Comparable {
    static func < (lhs: DiskCleanRisk, rhs: DiskCleanRisk) -> Bool {
        lhs.severity < rhs.severity
    }

    private var severity: Int {
        switch self {
        case .low:
            return 0
        case .medium:
            return 1
        case .high:
            return 2
        }
    }
}

// MARK: - 分类

/// 规则 v2 的十个清理分类（设计 §5.1）。
///
/// 每个分类携带 `risk`（仅用于展示排序与文案语气）、一句诚实的 `consequence` 后果文案，以及 SF Symbol。
/// 单个候选是否默认勾选由 **target 级** `risk` 决定，不看分类 risk——分类内允许混合风险
/// （例如 `developer` 分类下 `developer.docker` 是 medium，其余多为 low）。
enum DiskCleanCategoryID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case userEssentials
    case appCaches
    case systemCaches
    case logs
    case developer
    case browsers
    case cloudOffice
    case communication
    case aiTools
    case virtualization
    /// P2 开发产物清扫（设计 §10.1）。候选来自用户配置的扫描根，不由规则 glob 展开。
    case developerArtifacts
    /// P2 残留安装包（设计 §10.2）。
    case installers

    var id: String { rawValue }

    /// 详情页与面板的展示顺序：风险低 → 高（设计 §5.1）。
    /// `DiskCleanRisk` 只有三级而分类有十几个，故顺序由本表给出，`risk` 仅保证本表单调不减。
    ///
    /// 两个 P2 分类排在末尾，但它们实际不与规则分类同框——各自渲染在详情页的独立分段里，
    /// 顺序只在分段内部生效。放进本表是因为分组一律按本表过滤，缺席等于分组被静默丢弃。
    static let displayOrder: [DiskCleanCategoryID] = [
        .userEssentials,
        .appCaches,
        .logs,
        .browsers,
        .cloudOffice,
        .communication,
        .aiTools,
        .developer,
        .systemCaches,
        .virtualization,
        .installers,
        .developerArtifacts
    ]

    var risk: DiskCleanRisk {
        switch self {
        case .userEssentials, .appCaches, .logs, .browsers, .cloudOffice, .communication, .aiTools:
            return .low
        // 安装包不是缓存而是用户自己的文件，删错了没有"自动重建"这回事，
        // 只能重新下载——展示上与开发产物同级。
        case .developer, .systemCaches, .virtualization, .developerArtifacts, .installers:
            return .medium
        }
    }

    var symbolName: String {
        switch self {
        case .userEssentials:
            return "person.crop.circle"
        case .appCaches:
            return "square.grid.2x2"
        case .systemCaches:
            return "gearshape"
        case .logs:
            return "doc.text"
        case .developer:
            return "hammer"
        case .browsers:
            return "safari"
        case .cloudOffice:
            return "cloud"
        case .communication:
            return "bubble.left.and.bubble.right"
        case .aiTools:
            return "sparkles"
        case .virtualization:
            return "cube"
        case .developerArtifacts:
            return "shippingbox"
        case .installers:
            return "arrow.down.circle"
        }
    }

    var titleKey: String { "category.\(rawValue).title" }

    var consequenceKey: String { "category.\(rawValue).consequence" }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        localization.string(titleKey, defaultValue: defaultTitle)
    }

    /// 一句诚实的后果文案。不承诺"无影响"，也不夸大风险。
    func consequence(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        localization.string(consequenceKey, defaultValue: defaultConsequence)
    }

    private var defaultTitle: String {
        switch self {
        case .userEssentials:
            return "用户缓存"
        case .appCaches:
            return "应用缓存"
        case .systemCaches:
            return "系统状态缓存"
        case .logs:
            return "日志与诊断报告"
        case .developer:
            return "开发者缓存"
        case .browsers:
            return "浏览器缓存"
        case .cloudOffice:
            return "云盘与办公"
        case .communication:
            return "通讯应用"
        case .aiTools:
            return "AI 工具"
        case .virtualization:
            return "虚拟化"
        case .developerArtifacts:
            return "开发产物"
        case .installers:
            return "残留安装包"
        }
    }

    private var defaultConsequence: String {
        switch self {
        case .userEssentials:
            return "应用首次启动会稍慢，登录状态与文档不受影响。"
        case .appCaches:
            return "相关应用首次打开会稍慢，缩略图与预览需要重新生成。"
        case .systemCaches:
            return "下次打开应用可能不恢复上次的窗口，预览缩略图需要重建。"
        case .logs:
            return "历史日志与诊断报告会丢失，反馈问题时可能缺少记录。"
        case .developer:
            return "首次构建会变慢，依赖与索引需要重新下载或生成。"
        case .browsers:
            return "首次访问网站会稍慢，书签与登录状态不受影响。"
        case .cloudOffice:
            return "云盘与办公应用需要重建本地缓存，同步会短暂变慢。"
        case .communication:
            return "聊天记录不受影响，图片与文件需要重新下载。"
        case .aiTools:
            return "对话记录不受影响，模型与界面资源需要重新缓存。"
        case .virtualization:
            return "虚拟机磁盘不受影响，快照缓存与临时文件需要重建。"
        case .developerArtifacts:
            return "源码与提交不受影响，依赖需要重新安装、产物需要重新构建。"
        case .installers:
            return "已安装的应用不受影响，安装包需要时可重新下载。"
        }
    }
}

// MARK: - target 级规则

/// 规则 v2 的清理目标（设计 §5.2）。
///
/// v1 以"规则"为粒度携带风险，v2 下沉到 target：同一条 v1 规则可拆成多个 target
/// （例如 `cache.user-essentials` 拆成用户缓存与用户日志两个分类），拆分后各自带自己的分类与风险。
/// `legacyRuleID` 保留 v1 规则 id，供审计日志、白名单迁移与映射快照测试使用。
struct DiskCleanRuleTarget: Identifiable, Sendable {
    enum Kind: Sendable {
        /// 静态 glob 组。同一 target 内的 glob 共享分类、风险与锁定条件。
        case path(globs: [String])
        /// 动态展开（simctl、版本目录比较等，见 `DiskCleanDynamicRules`）。
        case dynamic(provider: any DiskCleanDynamicRuleProviding)
        /// 候选由专用扫描器发现，引擎不展开本 target（设计 §10 的 P2 合成 target）。
        ///
        /// 存在的理由只有一个：**删除必须经 Planner 铸造的计划**，而 Planner 用 `targetID`
        /// 回查目录取锁定声明。P2 候选因此必须挂在真实存在的 target 上，否则就得给它们开
        /// 第二条铸造路径——那正是这套设计要杜绝的。
        case external
    }

    /// 稳定 target ID。单 target 规则沿用 v1 规则 id，拆分出的 target 追加后缀。
    let id: String
    /// v1 规则 id。多个 target 可共享同一个 legacyRuleID。
    let legacyRuleID: String
    let category: DiskCleanCategoryID
    /// target 级风险。默认勾选策略只看这里（`.low` 才默认勾选）。
    let risk: DiskCleanRisk
    let kind: Kind
    /// 规范化的绝对保留根（可含 `~` 前缀，使用前经 `expandedReservedRootPaths` 展开）。
    ///
    /// **必填，且与 target 是否成功运行无关**（设计 §5.2、§6.1）：target 被 FDA 跳过或动态 provider
    /// 失败时，这些路径下的内容被视为"存在但未扫描"，Planner 据此禁止删除它们的祖先，
    /// 避免顺带删掉从未审查过的子树。path 类由 glob 的固定目录前缀推导后写死为字面量。
    let reservedRootPaths: [String]
    /// 未授予完全磁盘访问时是否整体跳过（设计 §9）。仅当 target 的全部 glob 都在 TCC 保护范围内才置 true，
    /// 否则宁可让个别路径以 `permissionDenied` 降级，也不牺牲同 target 内其他可清理路径。
    let requiresFullDiskAccess: Bool
    /// 运行中即锁定的应用 bundle ID（`NSWorkspace.runningApplications` 快照判定）。
    let lockedByBundleIDs: [String]
    /// 运行中即锁定的进程名（批量 pgrep 快照判定，覆盖非 App 进程）。
    let skipWhenProcessIsRunning: [String]

    init(
        id: String,
        legacyRuleID: String,
        category: DiskCleanCategoryID,
        risk: DiskCleanRisk,
        kind: Kind,
        reservedRootPaths: [String],
        requiresFullDiskAccess: Bool = false,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) {
        self.id = id
        self.legacyRuleID = legacyRuleID
        self.category = category
        self.risk = risk
        self.kind = kind
        self.reservedRootPaths = reservedRootPaths
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.lockedByBundleIDs = lockedByBundleIDs
        self.skipWhenProcessIsRunning = skipWhenProcessIsRunning
    }

    var pathGlobs: [String] {
        guard case let .path(globs) = kind else { return [] }
        return globs
    }

    var dynamicProvider: (any DiskCleanDynamicRuleProviding)? {
        guard case let .dynamic(provider) = kind else { return nil }
        return provider
    }

    var isDynamic: Bool { dynamicProvider != nil }

    /// 引擎的规则展开阶段是否跳过本 target。
    var isExternallyDiscovered: Bool {
        if case .external = kind { return true }
        return false
    }

    /// 展开 `~` 前缀后的保留根。祖先断言与保留集一律使用展开结果，避免 `~` 与绝对路径混比。
    func expandedReservedRootPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        reservedRootPaths.map { Self.expandHome(in: $0, homeDirectory: homeDirectory) }
    }

    static func expandHome(in path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory + String(path.dropFirst())
    }
}
