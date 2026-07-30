import SwiftUI
import MacToolsPluginKit

// MARK: - 分组

/// 一个分类卡片的数据。视图从候选列表现算，不额外持有状态。
struct DiskCleanCategoryGroup: Identifiable, Equatable, Sendable {
    let category: DiskCleanCategoryID
    let candidates: [DiskCleanCandidate]
    let selectableCount: Int
    let selectedCount: Int
    let selectedEstimatedBytes: Int64

    var id: String { category.rawValue }

    /// 按 `DiskCleanCategoryID.displayOrder`（风险低 → 高）分组。空分类不出现。
    static func groups(
        candidates: [DiskCleanCandidate],
        selection: DiskCleanSelectionProjection
    ) -> [DiskCleanCategoryGroup] {
        let candidatesByCategory = Dictionary(grouping: candidates, by: \.category)
        return DiskCleanCategoryID.displayOrder.compactMap { category in
            guard let items = candidatesByCategory[category], !items.isEmpty else { return nil }
            let selected = items.filter { selection.isSelected($0.id) }
            return DiskCleanCategoryGroup(
                category: category,
                candidates: items,
                selectableCount: items.filter { selection.isSelectable($0.id) }.count,
                selectedCount: selected.count,
                selectedEstimatedBytes: selected.reduce(0) { $0 + max($1.estimatedBytes, 0) }
            )
        }
    }
}

// MARK: - 分类卡片列表

/// 详情页的分类卡片列表（设计 §8.3 第 3 项）。
struct DiskCleanCategoryListView: View {
    let groups: [DiskCleanCategoryGroup]
    let selection: DiskCleanSelectionProjection
    /// 上一次执行的逐项终态，用于"内容已变化"一类徽标。
    let outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome]
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let onToggleCandidate: (DiskCleanCandidate.ID, Bool) -> Void
    let onToggleCategory: (DiskCleanCategoryID, Bool) -> Void

    @Binding var expandedCategories: Set<DiskCleanCategoryID>

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            ForEach(groups) { group in
                DiskCleanCategoryCard(
                    group: group,
                    state: selection.state(of: group.category),
                    selection: selection,
                    outcomesByCandidateID: outcomesByCandidateID,
                    localization: localization,
                    isInteractionEnabled: isInteractionEnabled,
                    isExpanded: expandedCategories.contains(group.category),
                    onToggleExpanded: {
                        if expandedCategories.contains(group.category) {
                            expandedCategories.remove(group.category)
                        } else {
                            expandedCategories.insert(group.category)
                        }
                    },
                    onToggleCandidate: onToggleCandidate,
                    onToggleCategory: onToggleCategory
                )
            }
        }
    }
}

// MARK: - 分类卡片

private struct DiskCleanCategoryCard: View {
    let group: DiskCleanCategoryGroup
    let state: DiskCleanCategorySelectionState
    let selection: DiskCleanSelectionProjection
    let outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome]
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onToggleCandidate: (DiskCleanCandidate.ID, Bool) -> Void
    let onToggleCategory: (DiskCleanCategoryID, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                PluginSettingsListDivider()
                candidateRows
            }
        }
        .pluginSettingsCardBackground(.plugin)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            DiskCleanTriStateCheckbox(
                state: state,
                // "全选"= 选中本类所有低风险项；已有选中时点一下就是全部取消。
                // 三态勾选框最忌讳"点了没反应"，因此两个方向都保证有变化。
                onToggle: { onToggleCategory(group.category, !state.isChecked) },
                help: checkboxHelp
            )
            .disabled(!isInteractionEnabled || !state.isSelectable)

            Image(systemName: group.category.symbolName)
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(group.category.title(localization: localization))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(group.category.consequence(localization: localization))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(countSummary)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Text(DiskCleanFormat.approximateBytes(group.selectedEstimatedBytes, localization: localization))
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)

            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(PluginSettingsTheme.Typography.rowIcon)
            }
            .buttonStyle(.borderless)
            .help(
                isExpanded
                    ? localization.string("detail.category.collapse", defaultValue: "收起项目")
                    : localization.string("detail.category.expand", defaultValue: "展开项目")
            )
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var candidateRows: some View {
        VStack(spacing: 0) {
            ForEach(group.candidates) { candidate in
                DiskCleanCandidateRow(
                    candidate: candidate,
                    isSelected: selection.isSelected(candidate.id),
                    isSelectable: selection.isSelectable(candidate.id),
                    outcome: outcomesByCandidateID[candidate.id],
                    localization: localization,
                    isInteractionEnabled: isInteractionEnabled,
                    onToggle: { onToggleCandidate(candidate.id, $0) }
                )
                if candidate.id != group.candidates.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    private var countSummary: String {
        localization.format(
            "detail.category.counts",
            defaultValue: "共 %d 项 · 可清理 %d 项 · 已选 %d 项",
            group.candidates.count,
            group.selectableCount,
            group.selectedCount
        )
    }

    private var checkboxHelp: String {
        state.isChecked
            ? localization.string("detail.category.deselectAll", defaultValue: "取消选择本类全部项目")
            : localization.string("detail.category.selectLowRisk", defaultValue: "选中本类所有低风险项目")
    }
}

// MARK: - 候选行

private struct DiskCleanCandidateRow: View {
    let candidate: DiskCleanCandidate
    let isSelected: Bool
    let isSelectable: Bool
    let outcome: DiskCleanExecutionItemResult.Outcome?
    let localization: PluginLocalization
    let isInteractionEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!isInteractionEnabled || !isSelectable)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(candidate.displayName)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.path)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !badges.isEmpty {
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        ForEach(badges) { badge in
                            DiskCleanBadgeLabel(badge: badge)
                        }
                    }
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Text(sizeText)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(candidate.sizeResult == nil ? Color.secondary : Color.primary)
                .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)
        }
        .pluginSettingsListRowPadding()
    }

    /// 未定大小显示"计算中"而不是"0 字节"——后者会让用户以为这一项是空的。
    private var sizeText: String {
        guard candidate.sizeResult != nil else {
            return localization.string("detail.candidate.sizing", defaultValue: "计算中…")
        }
        return DiskCleanFormat.approximateBytes(candidate.estimatedBytes, localization: localization)
    }

    private var badges: [DiskCleanBadge] {
        DiskCleanBadge.badges(for: candidate, outcome: outcome, localization: localization)
    }
}

// MARK: - 徽标

struct DiskCleanBadge: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case warning
    }

    let id: String
    let text: String
    let tone: Tone

    /// 逐项徽标（设计 §8.3）：使用中 / 白名单 / 保护 / 部分-原因 / 内容已变化 / 挂载点 / 计算中。
    ///
    /// 顺序即优先级：先说"上次清理时发生了什么"，再说"现在为什么不能选"。
    static func badges(
        for candidate: DiskCleanCandidate,
        outcome: DiskCleanExecutionItemResult.Outcome?,
        localization: PluginLocalization
    ) -> [DiskCleanBadge] {
        var badges: [DiskCleanBadge] = []

        if let outcome {
            badges.append(contentsOf: self.badges(for: outcome, localization: localization))
        }

        // 候选自身的事实（P2 的仓库状态、安装包年龄）排在安全状态之前：
        // 它们解释的是"为什么这一项没被默认勾选"，用户看到未勾选的第一反应就是找这个理由。
        badges += candidate.notes.compactMap { badge(for: $0, localization: localization) }

        switch candidate.safety {
        case .allowed:
            break
        case let .inUse(processName):
            badges.append(
                DiskCleanBadge(
                    id: "inUse",
                    text: localization.format("badge.inUse", defaultValue: "使用中：%@", processName),
                    tone: .warning
                )
            )
        case .whitelisted:
            badges.append(
                DiskCleanBadge(
                    id: "whitelisted",
                    text: localization.string("badge.whitelisted", defaultValue: "白名单"),
                    tone: .neutral
                )
            )
        case .protected:
            badges.append(
                DiskCleanBadge(
                    id: "protected",
                    text: localization.string("badge.protected", defaultValue: "受保护"),
                    tone: .neutral
                )
            )
        case .invalid:
            badges.append(
                DiskCleanBadge(
                    id: "invalid",
                    text: localization.string("badge.invalid", defaultValue: "路径不安全"),
                    tone: .neutral
                )
            )
        case .requiresAdmin:
            badges.append(
                DiskCleanBadge(
                    id: "requiresAdmin",
                    text: localization.string("badge.requiresAdmin", defaultValue: "需要管理员"),
                    tone: .neutral
                )
            )
        }

        guard let sizeResult = candidate.sizeResult else {
            badges.append(
                DiskCleanBadge(
                    id: "sizing",
                    text: localization.string("badge.sizing", defaultValue: "计算中"),
                    tone: .neutral
                )
            )
            return badges
        }

        let reasons = sizeResult.completeness.partialReasons
        // 挂载点单列：它不是"没算完"，而是"这个目录里有别的卷，删它会越界"。
        if reasons.contains(.crossedMountPoint) {
            badges.append(
                DiskCleanBadge(
                    id: "crossedMountPoint",
                    text: localization.string("badge.crossedMountPoint", defaultValue: "含挂载点"),
                    tone: .warning
                )
            )
        }
        let otherReasons = reasons.subtracting([.crossedMountPoint])
        if !otherReasons.isEmpty {
            badges.append(
                DiskCleanBadge(
                    id: "partial",
                    text: localization.format(
                        "badge.partial",
                        defaultValue: "扫描不完整：%@",
                        DiskCleanFormat.partialReasons(otherReasons, localization: localization)
                    ),
                    tone: .warning
                )
            )
        }

        return badges
    }

    /// 候选附注徽标（设计 §10 的 P2 徽标体系）。
    ///
    /// "所属工程"不出徽标：它是候选的**定位信息**而非警示，挤在一行胶囊里会把真正需要注意的
    /// "仓库有未提交改动"淹掉。工程路径由候选行的路径本身表达。
    private static func badge(
        for note: DiskCleanCandidateNote,
        localization: PluginLocalization
    ) -> DiskCleanBadge? {
        switch note {
        case let .repositoryHasChanges(_, reason):
            return DiskCleanBadge(
                id: "repositoryHasChanges",
                text: repositoryChangeText(reason, localization: localization),
                tone: .warning
            )
        case .mayNotBeInstaller:
            return DiskCleanBadge(
                id: "mayNotBeInstaller",
                text: localization.string("badge.mayNotBeInstaller", defaultValue: "未必是安装包"),
                tone: .neutral
            )
        case let .recentlyDownloaded(modifiedAt):
            return DiskCleanBadge(
                id: "recentlyDownloaded",
                text: localization.format(
                    "badge.recentlyDownloaded",
                    defaultValue: "近期下载：%@",
                    DiskCleanFormat.timestamp(modifiedAt)
                ),
                tone: .neutral
            )
        case .developerProject:
            return nil
        }
    }

    /// 检查失败与真有改动分开说：前者是"没查出来，按有改动处理"，把它写成"有未提交改动"
    /// 是在编造一个用户去仓库里找不到的事实。
    private static func repositoryChangeText(
        _ reason: DiskCleanPurgeGitState.DirtyReason,
        localization: PluginLocalization
    ) -> String {
        switch reason {
        case .uncommittedChanges:
            return localization.string("badge.repository.uncommitted", defaultValue: "仓库有未提交改动")
        case .unpushedCommits:
            return localization.string("badge.repository.unpushed", defaultValue: "仓库有未推送提交")
        case let .inspectionFailed(detail):
            return localization.format(
                "badge.repository.inspectionFailed",
                defaultValue: "无法确认仓库状态：%@",
                detail
            )
        }
    }

    private static func badges(
        for outcome: DiskCleanExecutionItemResult.Outcome,
        localization: PluginLocalization
    ) -> [DiskCleanBadge] {
        switch outcome {
        case .changedSinceScan:
            return [
                DiskCleanBadge(
                    id: "changedSinceScan",
                    text: localization.string("badge.changedSinceScan", defaultValue: "内容已变化，请重新扫描"),
                    tone: .warning
                )
            ]
        case .partiallyDeleted:
            return [
                DiskCleanBadge(
                    id: "partiallyDeleted",
                    text: localization.string("badge.partiallyDeleted", defaultValue: "只删除了一部分"),
                    tone: .warning
                )
            ]
        case .rollbackBlocked:
            return [
                DiskCleanBadge(
                    id: "rollbackBlocked",
                    text: localization.string("badge.rollbackBlocked", defaultValue: "无法放回原处"),
                    tone: .warning
                )
            ]
        case let .failed(message):
            return [DiskCleanBadge(id: "failed", text: message, tone: .warning)]
        case .removed, .trashed, .skipped:
            return []
        }
    }
}

struct DiskCleanBadgeLabel: View {
    let badge: DiskCleanBadge

    var body: some View {
        Text(badge.text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(badge.tone == .warning ? Color.orange : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )
    }
}

// MARK: - 三态勾选框

/// 三态勾选框。
///
/// `Toggle` 只有开/关两态，而分类勾选必须能表达"选了一部分"——含 medium/high 项的分类
/// 在"全选低风险"之后必然停在 mixed，用两态控件表示会一直显示"未全选"，
/// 用户会以为自己点错了。
struct DiskCleanTriStateCheckbox: View {
    let state: DiskCleanCategorySelectionState
    let onToggle: () -> Void
    let help: String

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: symbolName)
                .font(.system(size: 14))
                .foregroundStyle(state.isChecked ? Color.accentColor : Color.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var symbolName: String {
        switch state {
        case .allSelected:
            return "checkmark.square.fill"
        case .partiallySelected:
            return "minus.square.fill"
        case .noneSelected, .unavailable:
            return "square"
        }
    }
}
