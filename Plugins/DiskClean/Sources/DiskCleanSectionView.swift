import SwiftUI
import MacToolsPluginKit

// MARK: - 分段引导态

/// 一个分段在"没有候选可展示"时该说什么（设计 §10）。
///
/// 纯派生、无视图依赖，因此可以直接对着快照断言。存在的理由是几个**必须区分开**的空态：
/// 没配扫描根、没扫过、扫了但被拒绝、根失效、真的没有——它们对用户的下一步动作要求完全不同，
/// 混成一个"暂无内容"等于让用户自己去猜。
enum DiskCleanSectionGuidance: Equatable, Sendable {
    /// 正常展示候选列表。
    case candidates
    /// 开发产物段还没配置任何扫描根。
    case needsRoots
    /// 还没扫过。
    case notScanned
    /// 扫描根被拒绝访问（TCC）。**绝不能显示成"没有可清理项"**——
    /// `~/Downloads` 里可能正躺着几十 GB 安装包。
    case accessDenied(path: String)
    /// 扫描根打不开：已删除、被换成文件、或在非本地卷上。
    case rootsUnreadable(paths: [String])
    /// 扫过了，确实没有。
    case empty

    static func resolve(_ snapshot: DiskCleanControllerSnapshot) -> DiskCleanSectionGuidance {
        if case .developerArtifacts = snapshot.scope, snapshot.scope.isEmpty {
            return .needsRoots
        }
        guard let result = snapshot.scanResult else { return .notScanned }
        // 有候选就正常展示；根的问题由受限横幅如实说明，不必占掉整个列表位置。
        guard result.candidates.isEmpty else { return .candidates }

        let unreadable = result.limitations.compactMap { limitation -> (String, DiskCleanScanCompleteness.PartialReason)? in
            guard case let .scanRootUnreadable(path, reason) = limitation else { return nil }
            return (path, reason)
        }
        if let denied = unreadable.first(where: { $0.1 == .permissionDenied }) {
            return .accessDenied(path: denied.0)
        }
        if !unreadable.isEmpty {
            return .rootsUnreadable(paths: unreadable.map(\.0))
        }
        return .empty
    }
}

// MARK: - 复用片段

/// 横幅（受限、错误、FDA 引导共用）。
struct DiskCleanBanner<Trailing: View>: View {
    let symbolName: String
    let tint: Color
    let title: String
    let lines: [String]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            trailing()
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.plugin)
    }
}

extension DiskCleanBanner where Trailing == EmptyView {
    init(symbolName: String, tint: Color, title: String, lines: [String]) {
        self.init(symbolName: symbolName, tint: tint, title: title, lines: lines) { EmptyView() }
    }
}

/// 空态。可选一个行动按钮——空态如果只说"没有内容"而用户其实需要先做一步配置，
/// 那这个空态就是死路。
struct DiskCleanEmptyState<Action: View>: View {
    let symbolName: String
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: symbolName)
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
        .pluginSettingsCardBackground(.plugin)
    }
}

extension DiskCleanEmptyState where Action == EmptyView {
    init(symbolName: String, text: String) {
        self.init(symbolName: symbolName, text: text) { EmptyView() }
    }
}

struct DiskCleanSectionHeader: View {
    let title: String
    let symbolName: String

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}

/// 扫描 / 清理 / 停止 + 选择摘要。三个分段共用一条，行为与文案因此不可能各说各话。
struct DiskCleanActionBar: View {
    let snapshot: DiskCleanControllerSnapshot
    let localization: PluginLocalization
    let onScan: () -> Void
    let onClean: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button(action: onScan) {
                Label(
                    localization.string("detail.action.scan", defaultValue: "扫描"),
                    systemImage: "magnifyingglass"
                )
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!snapshot.canScan)

            Button(action: onClean) {
                Label(
                    DiskCleanFormat.cleanActionTitle(snapshot, localization: localization),
                    systemImage: "trash"
                )
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!snapshot.canClean)

            if snapshot.isBusy {
                Button(action: onCancel) {
                    Label(
                        localization.string("detail.action.stop", defaultValue: "停止"),
                        systemImage: "xmark.circle"
                    )
                    .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if snapshot.phase == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }

            Spacer(minLength: 0)

            Text(DiskCleanFormat.selectionSummary(snapshot, localization: localization))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - P2 分段

/// 开发产物 / 残留安装包分段（设计 §8.3 第 4 项、§10）。
///
/// 与规则分段共用同一个 `DiskCleanController`：候选、选择、计划铸造、执行全部走同一条管线，
/// 这里只负责把"扫描入口 + 引导态 + 候选列表"摆好。**独立扫描入口**是设计要求——
/// 开发产物要遍历用户工程目录、安装包会触发 `~/Downloads` 的 TCC 弹窗，
/// 两者都不该被常规缓存扫描顺手带上。
struct DiskCleanCleanupSectionView<Configuration: View>: View {
    @ObservedObject var controller: DiskCleanController
    let title: String
    let symbolName: String
    let localization: PluginLocalization
    /// 分段特有的配置区（开发产物段的扫描根管理）。
    @ViewBuilder let configuration: () -> Configuration

    @State private var expandedCategories: Set<DiskCleanCategoryID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(title: title, symbolName: symbolName)

            configuration()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                DiskCleanActionBar(
                    snapshot: snapshot,
                    localization: localization,
                    onScan: { controller.scan() },
                    onClean: { controller.clean() },
                    onCancel: { controller.cancelCurrentOperation() }
                )
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.plugin)

            if let errorMessage = snapshot.errorMessage {
                DiskCleanBanner(
                    symbolName: "xmark.octagon.fill",
                    tint: .red,
                    title: localization.string("detail.error.title", defaultValue: "操作未完成"),
                    lines: [errorMessage]
                )
            }

            content
        }
        .confirmationDialog(
            DiskCleanFormat.confirmationTitle(snapshot, localization: localization),
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                controller.confirmPendingClean()
            } label: {
                Text(localization.string("detail.confirm.confirm", defaultValue: "永久删除"))
            }
            Button(role: .cancel) {
                controller.cancelPendingClean()
            } label: {
                Text(localization.string("detail.action.cancelClean", defaultValue: "取消"))
            }
        } message: {
            Text(
                localization.string(
                    "detail.confirm.message",
                    defaultValue: "永久删除不进废纸篓，无法恢复。"
                )
            )
        }
    }

    private var snapshot: DiskCleanControllerSnapshot {
        controller.snapshot
    }

    @ViewBuilder
    private var content: some View {
        switch DiskCleanSectionGuidance.resolve(snapshot) {
        case .candidates:
            DiskCleanCategoryListView(
                groups: DiskCleanCategoryGroup.groups(
                    candidates: snapshot.scanResult?.candidates ?? [],
                    selection: snapshot.selection
                ),
                selection: snapshot.selection,
                outcomesByCandidateID: outcomesByCandidateID,
                localization: localization,
                isInteractionEnabled: !snapshot.isBusy,
                onToggleCandidate: { controller.setCandidateSelected($0, isSelected: $1) },
                onToggleCategory: { controller.setCategorySelection($0, isSelected: $1) },
                expandedCategories: $expandedCategories
            )

        case .needsRoots:
            // 空态本身不带"添加文件夹"按钮：入口在上方的扫描根管理区，两处各放一个
            // 会让用户以为它们是两件事。
            DiskCleanEmptyState(
                symbolName: "folder.badge.plus",
                text: localization.string(
                    "detail.developerArtifacts.needsRoots",
                    defaultValue: "先添加要扫描的工程文件夹，只会扫描你指定的目录"
                )
            )

        case .notScanned:
            DiskCleanEmptyState(
                symbolName: "magnifyingglass",
                text: localization.string(
                    "detail.section.notScanned",
                    defaultValue: "点击「扫描」查看可清理内容"
                )
            )

        case let .accessDenied(path):
            DiskCleanBanner(
                symbolName: "lock.fill",
                tint: .orange,
                title: localization.string(
                    "detail.section.accessDenied.title",
                    defaultValue: "没有访问权限，无法确认里面有什么"
                ),
                lines: [
                    localization.format(
                        "detail.section.accessDenied.message",
                        defaultValue: "系统拒绝了对 %@ 的访问。在系统设置里允许后重新扫描。",
                        path
                    )
                ]
            ) {
                Button {
                    DiskCleanFullDiskAccessGuide.openSettings()
                } label: {
                    Text(localization.string("detail.fda.openSettings", defaultValue: "前往授权"))
                        .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case let .rootsUnreadable(paths):
            DiskCleanBanner(
                symbolName: "questionmark.folder",
                tint: .orange,
                title: localization.string(
                    "detail.section.rootsUnreadable.title",
                    defaultValue: "有文件夹已无法读取"
                ),
                lines: paths.map {
                    localization.format(
                        "detail.section.rootsUnreadable.line",
                        defaultValue: "%@ 已被移除、替换或位于其他卷上。",
                        $0
                    )
                }
            )

        case .empty:
            DiskCleanEmptyState(
                symbolName: "checkmark.circle",
                text: localization.string("detail.candidates.empty", defaultValue: "没有发现可清理项目")
            )
        }
    }

    private var outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome] {
        guard let executionResult = snapshot.executionResult else { return [:] }
        return Dictionary(
            executionResult.itemResults.map { ($0.candidateID, $0.outcome) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { snapshot.phase == .confirming },
            set: { isPresented in
                guard !isPresented else { return }
                controller.cancelPendingClean()
            }
        )
    }
}

extension DiskCleanCleanupSectionView where Configuration == EmptyView {
    init(
        controller: DiskCleanController,
        title: String,
        symbolName: String,
        localization: PluginLocalization
    ) {
        self.init(
            controller: controller,
            title: title,
            symbolName: symbolName,
            localization: localization
        ) {
            EmptyView()
        }
    }
}
