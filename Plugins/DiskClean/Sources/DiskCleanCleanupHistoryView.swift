import SwiftUI
import MacToolsPluginKit

// MARK: - 历史条目

/// 清理历史条目的状态。
///
/// 取值域与审计日志写入的 `status` 字符串一一对应（`DiskCleanExecutor.status(of:)` 与
/// `DiskCleanStagingReconciler.record(for:)`）。解析而不是直接展示原始字符串，是因为
/// "哪些状态需要置顶提示"是一条产品判断，必须有唯一的落点。
enum DiskCleanCleanupHistoryStatus: Equatable, Sendable {
    case ok
    case skipped
    case changedSinceScan
    case failed
    case partiallyDeleted
    case rollbackBlocked
    case reconciledRolledBack
    case reconciledAbsent
    case reconcileFailed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "ok":
            self = .ok
        case "skipped":
            self = .skipped
        case "changedSinceScan":
            self = .changedSinceScan
        case "failed":
            self = .failed
        case "partiallyDeleted":
            self = .partiallyDeleted
        case "rollbackBlocked":
            self = .rollbackBlocked
        case "reconciledRolledBack":
            self = .reconciledRolledBack
        // 父目录整个消失与暂存对象消失是同一个结论：没有需要恢复的东西。
        case "reconciledAbsent", "reconciledParentMissing":
            self = .reconciledAbsent
        case "reconcileFailed":
            self = .reconcileFailed
        default:
            self = .unknown(rawValue)
        }
    }

    /// 需要置顶提示的诚实终态（设计 §7.5、§13-M4-6）。
    ///
    /// 三者的共同点：磁盘上留下了一个用户不知道的暂存对象，或者一次删除只做了一半。
    /// 普通的 `failed`/`skipped` 没有留下残骸，不需要打扰用户。
    var needsAttention: Bool {
        switch self {
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return true
        case .ok, .skipped, .changedSinceScan, .failed,
             .reconciledRolledBack, .reconciledAbsent, .unknown:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .skipped, .changedSinceScan:
            return "minus.circle"
        case .failed:
            return "xmark.circle"
        case .partiallyDeleted, .rollbackBlocked, .reconcileFailed:
            return "exclamationmark.triangle.fill"
        case .reconciledRolledBack:
            return "arrow.uturn.backward.circle"
        case .reconciledAbsent:
            return "circle"
        case .unknown:
            return "circle"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .ok:
            return localization.string("history.status.ok", defaultValue: "已清理")
        case .skipped:
            return localization.string("history.status.skipped", defaultValue: "已跳过")
        case .changedSinceScan:
            return localization.string("history.status.changed", defaultValue: "内容已变化")
        case .failed:
            return localization.string("history.status.failed", defaultValue: "失败")
        case .partiallyDeleted:
            return localization.string("history.status.partiallyDeleted", defaultValue: "只删除了一部分")
        case .rollbackBlocked:
            return localization.string("history.status.rollbackBlocked", defaultValue: "无法放回原处")
        case .reconciledRolledBack:
            return localization.string("history.status.reconciledRolledBack", defaultValue: "启动时已放回")
        case .reconciledAbsent:
            return localization.string("history.status.reconciledAbsent", defaultValue: "上次已完成")
        case .reconcileFailed:
            return localization.string("history.status.reconcileFailed", defaultValue: "未完成，待处理")
        case let .unknown(rawValue):
            return rawValue
        }
    }
}

/// 一条清理历史。审计记录的展示投影。
struct DiskCleanCleanupHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Date
    let status: DiskCleanCleanupHistoryStatus
    let path: String?
    /// 暂存名。废纸篓模式下"放回"会落在这个名字上，需要展示给用户（设计 §7.4）。
    let stagedName: String?
    let estimatedBytes: Int64?
    let errorMessage: String?

    var needsAttention: Bool { status.needsAttention }

    /// 审计记录 → 展示条目。**需要关注的条目置顶**（设计 §13-M4-6），其余保持时间倒序。
    ///
    /// 置顶而不是只标红：`partiallyDeleted` / `rollbackBlocked` 意味着磁盘上有残骸，
    /// 埋在 200 条历史中间等于没说。
    static func entries(from records: [DiskCleanAuditLog.Record]) -> [DiskCleanCleanupHistoryEntry] {
        let entries = records.enumerated().map { index, record in
            DiskCleanCleanupHistoryEntry(
                id: index,
                timestamp: record.timestamp,
                status: DiskCleanCleanupHistoryStatus(rawValue: record.status),
                path: record.path,
                stagedName: record.stagedName,
                estimatedBytes: record.estimatedBytes,
                errorMessage: record.error
            )
        }
        return entries.filter(\.needsAttention) + entries.filter { !$0.needsAttention }
    }
}

// MARK: - 读取

/// 清理历史的读取 seam。审计日志在磁盘上，读取不占主线程。
protocol DiskCleanCleanupHistoryProviding: Sendable {
    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry]
}

struct DiskCleanAuditLogHistoryProvider: DiskCleanCleanupHistoryProviding {
    let directory: URL

    func recentEntries(limit: Int) async -> [DiskCleanCleanupHistoryEntry] {
        let directory = directory
        let records = await Task.detached(priority: .utility) {
            DiskCleanAuditLog(directory: directory).recentRecords(limit: limit)
        }.value
        return DiskCleanCleanupHistoryEntry.entries(from: records)
    }
}

// MARK: - 视图

/// 清理历史分段。展开时才读盘——设置页每次出现都扫一遍日志文件没有必要。
struct DiskCleanCleanupHistorySection: View {
    let provider: any DiskCleanCleanupHistoryProviding
    let localization: PluginLocalization

    private static let recordLimit = 100

    @State private var isExpanded = false
    @State private var entries: [DiskCleanCleanupHistoryEntry] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .padding(.top, PluginSettingsTheme.Spacing.sectionHeaderContent)
            } label: {
                Text(localization.string("detail.history.title", defaultValue: "清理历史"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            isLoading = true
            entries = await provider.recentEntries(limit: Self.recordLimit)
            isLoading = false
        }
    }

    /// 刷新按钮放在内容区而不是 DisclosureGroup 的 label 里：
    /// label 的点击区域属于展开/收起，塞一个按钮进去两者会互相抢。
    private var reloadButton: some View {
        Button {
            Task { entries = await provider.recentEntries(limit: Self.recordLimit) }
        } label: {
            Label(
                localization.string("detail.history.reload", defaultValue: "刷新"),
                systemImage: "arrow.clockwise"
            )
            .font(PluginSettingsTheme.Typography.controlLabel)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isLoading)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                ProgressView().controlSize(.small)
                Text(localization.string("detail.history.loading", defaultValue: "正在读取记录…"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .pluginSettingsListRowPadding()
        } else if entries.isEmpty {
            Text(localization.string("detail.history.empty", defaultValue: "还没有清理记录"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsListRowPadding()
                .pluginSettingsCardBackground(.plugin)
        } else {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                if let attentionCount {
                    attentionBanner(count: attentionCount)
                }

                HStack {
                    Spacer()
                    reloadButton
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            DiskCleanCleanupHistoryRow(entry: entry, localization: localization)
                            if entry.id != entries.last?.id {
                                PluginSettingsListDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .pluginSettingsCardBackground(.plugin)
            }
        }
    }

    private var attentionCount: Int? {
        let count = entries.filter(\.needsAttention).count
        return count > 0 ? count : nil
    }

    private func attentionBanner(count: Int) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(
                    localization.format(
                        "detail.history.attention.title",
                        defaultValue: "有 %d 项清理未完成",
                        count
                    )
                )
                .font(PluginSettingsTheme.Typography.rowTitle)

                Text(
                    localization.string(
                        "detail.history.attention.description",
                        defaultValue: "这些项目在磁盘上留下了以 .mactools-staged- 开头的暂存对象，可在下方记录里查看原路径后自行处理。"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.plugin)
    }
}

private struct DiskCleanCleanupHistoryRow: View {
    let entry: DiskCleanCleanupHistoryEntry
    let localization: PluginLocalization

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: entry.status.symbolName)
                .foregroundStyle(entry.needsAttention ? Color.orange : Color.secondary)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(entry.status.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Text(DiskCleanFormat.timestamp(entry.timestamp))
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }

                if let path = entry.path {
                    Text(path)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                // 废纸篓里的对象落在暂存名下，不展示它用户就找不回来（设计 §7.4）。
                if let stagedName = entry.stagedName {
                    Text(
                        localization.format(
                            "detail.history.stagedName",
                            defaultValue: "暂存名：%@",
                            stagedName
                        )
                    )
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }

                if let errorMessage = entry.errorMessage {
                    Text(errorMessage)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let bytes = entry.estimatedBytes {
                Text(DiskCleanFormat.approximateBytes(bytes, localization: localization))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(width: DiskCleanFormat.byteColumnWidth, alignment: .trailing)
            }
        }
        .pluginSettingsListRowPadding()
    }
}
