import Foundation

// MARK: - 分类三态

/// 分类勾选框的三态（设计 §8.1）。
///
/// `unavailable` 与 `noneSelected` 必须分开：前者是"本类没有任何可勾选项"（勾选框禁用，
/// 点了也不会有任何变化），后者是"有可勾选项但一个都没选"（点一下会全选低风险项）。
/// 合并成一个状态会让用户对着一个点不动的勾选框反复点。
///
/// 没有 `none` 这个名字：本类型会出现在字典值位置，`dict[key] = .none` 会被解读成
/// `Optional.none`（删除键），是个不该留下的陷阱。
enum DiskCleanCategorySelectionState: Equatable, Sendable {
    case unavailable
    case noneSelected
    case partiallySelected
    case allSelected

    var isSelectable: Bool {
        self != .unavailable
    }

    /// 勾选框当前是否呈"已勾选"外观（部分选中用横杠而不是对勾，由视图区分）。
    var isChecked: Bool {
        self == .allSelected || self == .partiallySelected
    }
}

// MARK: - 选择投影

/// 选择状态的只读投影。快照携带它，详情视图与菜单栏都只读这一份。
///
/// 菜单栏与详情页共享同一份权威选择（设计评审 round1-#5）：两个入口读同一个投影、
/// 发同样的命令，不存在"面板清理全部、详情页清理勾选项"这种两套语义。
struct DiskCleanSelectionProjection: Equatable, Sendable {
    let selectedIDs: Set<DiskCleanCandidate.ID>
    let selectableIDs: Set<DiskCleanCandidate.ID>
    let selectedEstimatedBytes: Int64
    let categoryStates: [DiskCleanCategoryID: DiskCleanCategorySelectionState]

    static let empty = DiskCleanSelectionProjection(
        selectedIDs: [],
        selectableIDs: [],
        selectedEstimatedBytes: 0,
        categoryStates: [:]
    )

    var selectedCount: Int { selectedIDs.count }

    var isEmpty: Bool { selectedIDs.isEmpty }

    func isSelected(_ candidateID: DiskCleanCandidate.ID) -> Bool {
        selectedIDs.contains(candidateID)
    }

    func isSelectable(_ candidateID: DiskCleanCandidate.ID) -> Bool {
        selectableIDs.contains(candidateID)
    }

    /// 未出现在本次扫描里的分类按 `unavailable` 处理——没有候选就没有可勾选项。
    func state(of category: DiskCleanCategoryID) -> DiskCleanCategorySelectionState {
        categoryStates[category] ?? .unavailable
    }
}

// MARK: - 选择模型

/// 三态选择的权威模型（设计 §8.1）。Controller 独占持有。
///
/// **本模型不存候选，只存"用户做过什么"**：每个候选的显式勾选覆盖，以及每个分类的显式全选/全不选。
/// 选中与否一律由 `(候选事实, 用户覆盖, 分类操作)` 现算。这样流式新增的候选不需要任何"补登记"
/// 步骤就自动落在正确的一侧——扫描期候选先无大小出现、随后被 `candidateSized` 补齐，
/// 一份增量维护的选中集在这两个时刻之间极易与候选事实脱节，现算则不可能脱节。
///
/// 三条语义（设计 §8.1）：
/// - **不可勾选即拒绝 toggle**，不是只在 UI 上禁用：锁定 / 白名单 / 保护 / 非 complete /
///   未求大小 / 含挂载点的候选，`setCandidate` 直接返回 false 不留任何记录。
/// - **默认勾选 = 低风险且可勾选**。medium/high 与动态规则产物（其 target 风险恒 >= medium）
///   一律不默认勾选。
/// - **"全选"= 选中本类所有低风险项**，medium/high 永不被全选带入（UI 文案同此表述）。
struct DiskCleanSelectionModel: Equatable, Sendable {
    /// 分类级显式操作。
    ///
    /// `selectAllLowRisk` 对**新到达**候选的影响与"从未操作过"完全相同（两者都落到默认策略），
    /// 记录它是为了覆盖掉此前的 `deselectAll`，并让"用户显式操作过这一类"这件事在模型里有名字。
    enum CategoryOperation: Equatable, Sendable {
        case selectAllLowRisk
        case deselectAll
    }

    private struct CandidateOverride: Equatable, Sendable {
        let category: DiskCleanCategoryID
        let isSelected: Bool
    }

    private var candidateOverrides: [DiskCleanCandidate.ID: CandidateOverride] = [:]
    private var categoryOperations: [DiskCleanCategoryID: CategoryOperation] = [:]

    init() {}

    // MARK: - 可勾选判定

    /// 是否可勾选。
    ///
    /// 与 `DiskCleanCandidate.isCleanable` 是同一个判定，不复制条件：设计 §8.1 列举的
    /// 六种不可勾选情形（锁定 / 白名单 / 保护 / 非 complete / 未求大小 / 含挂载点）逐条
    /// 落在 `isCleanable` 里，两处各写一份迟早会漂移。
    static func isSelectable(_ candidate: DiskCleanCandidate) -> Bool {
        candidate.isCleanable
    }

    /// 默认策略：低风险且可勾选。动态规则产物的 target 风险恒 >= medium，因此自动落在不勾选一侧。
    static func isSelectedByDefault(_ candidate: DiskCleanCandidate) -> Bool {
        isSelectable(candidate) && candidate.risk == .low
    }

    func isSelected(_ candidate: DiskCleanCandidate) -> Bool {
        guard Self.isSelectable(candidate) else { return false }
        if let override = candidateOverrides[candidate.id] {
            return override.isSelected
        }
        if categoryOperations[candidate.category] == .deselectAll {
            return false
        }
        return candidate.risk == .low
    }

    // MARK: - 命令

    /// 勾选/取消单个候选。返回是否被接受——不可勾选的候选一律拒绝，不留覆盖记录。
    @discardableResult
    mutating func setCandidate(_ candidate: DiskCleanCandidate, isSelected: Bool) -> Bool {
        guard Self.isSelectable(candidate) else { return false }
        candidateOverrides[candidate.id] = CandidateOverride(
            category: candidate.category,
            isSelected: isSelected
        )
        return true
    }

    /// 分类级全选（仅低风险）/ 全不选。
    ///
    /// 本类此前的逐项覆盖一并清除：分类操作是更粗的一笔，用户按下它就是要重置这一类的状态。
    mutating func setCategory(_ category: DiskCleanCategoryID, isSelected: Bool) {
        categoryOperations[category] = isSelected ? .selectAllLowRisk : .deselectAll
        candidateOverrides = candidateOverrides.filter { $0.value.category != category }
    }

    /// 回到"用户什么都没操作过"。新一轮扫描必须调用：候选 ID 是 `targetID::path`，
    /// 跨扫描稳定，不清空会把上一轮的勾选悄悄带进新结果。
    mutating func reset() {
        candidateOverrides = [:]
        categoryOperations = [:]
    }

    // MARK: - 派生

    func explicitOperation(for category: DiskCleanCategoryID) -> CategoryOperation? {
        categoryOperations[category]
    }

    func selectedIDs(in candidates: [DiskCleanCandidate]) -> Set<DiskCleanCandidate.ID> {
        Set(candidates.filter(isSelected).map(\.id))
    }

    /// 一次遍历算出快照需要的全部选择事实。
    func projection(for candidates: [DiskCleanCandidate]) -> DiskCleanSelectionProjection {
        var selectedIDs: Set<DiskCleanCandidate.ID> = []
        var selectableIDs: Set<DiskCleanCandidate.ID> = []
        var selectedBytes: Int64 = 0
        var selectableCountByCategory: [DiskCleanCategoryID: Int] = [:]
        var selectedCountByCategory: [DiskCleanCategoryID: Int] = [:]
        var categoryStates: [DiskCleanCategoryID: DiskCleanCategorySelectionState] = [:]

        for candidate in candidates {
            // 先登记分类存在性：全是不可勾选项的分类也要有状态（`unavailable`），
            // 否则视图无法区分"这一类没扫到东西"与"这一类全被保护了"。
            categoryStates[candidate.category] = .unavailable

            guard Self.isSelectable(candidate) else { continue }
            selectableIDs.insert(candidate.id)
            selectableCountByCategory[candidate.category, default: 0] += 1

            guard isSelected(candidate) else { continue }
            selectedIDs.insert(candidate.id)
            selectedBytes += max(candidate.estimatedBytes, 0)
            selectedCountByCategory[candidate.category, default: 0] += 1
        }

        for (category, selectableCount) in selectableCountByCategory where selectableCount > 0 {
            let selectedCount = selectedCountByCategory[category] ?? 0
            switch selectedCount {
            case 0:
                categoryStates[category] = .noneSelected
            case selectableCount:
                categoryStates[category] = .allSelected
            default:
                categoryStates[category] = .partiallySelected
            }
        }

        return DiskCleanSelectionProjection(
            selectedIDs: selectedIDs,
            selectableIDs: selectableIDs,
            selectedEstimatedBytes: selectedBytes,
            categoryStates: categoryStates
        )
    }
}
