import SwiftUI
import MacToolsPluginKit

struct MacSettingsOperationBanner: View {
    @ObservedObject var controller: MacSettingsController

    var body: some View {
        HStack(spacing: 12) {
            if let progress = controller.operationProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已处理 \(progress.completed) / \(progress.total) 项")
                        .monospacedDigit()
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .frame(width: 150)
                }
                Text(activeTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
                Text("正在读取当前值…")
                Spacer()
            }
            Button("停止") { controller.cancelOperation() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("当前设置完成验证或恢复后停止，不会开始后续更改。")
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .frame(height: 42)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityIdentifier("mac-settings.operation-progress")
        Divider()
    }

    private var activeTitle: String {
        guard let progress = controller.operationProgress,
              let id = progress.activeSettingID else { return "正在整理结果…" }
        let title = controller.catalog[id]?.definition.title ?? id.rawValue
        return "\(title) · \(progress.phase?.title ?? "处理中")"
    }
}

struct MacSettingsRecoveryView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var keepingID: SystemSettingID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(controller.pendingRecoveries.isEmpty ? "恢复记录未保存" : "恢复未完成", systemImage: "exclamationmark.triangle")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.orange)
                if !controller.pendingRecoveries.isEmpty {
                    Text("原始快照已保留。请先处理以下项目，再应用其他更改。")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                }
                if let error = controller.recoveryPersistenceError {
                    Text(error)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                    Button("重试保存恢复记录") { controller.retrySavingRecoveries() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!controller.canResolveRecovery)
                }
                ForEach(controller.pendingRecoveries.values.sorted { $0.id.rawValue < $1.id.rawValue }) { recovery in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(controller.catalog[recovery.id]?.definition.title ?? recovery.id.rawValue)
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            Spacer()
                            Button("重试恢复") { controller.retryRecovery(recovery.id) }
                            Button("保留当前值…") { keepingID = recovery.id }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!controller.canResolveRecovery)
                        Text(recovery.message)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        DisclosureGroup("查看当前值与原值") {
                            Text(recovery.differences.isEmpty
                                 ? "偏好值已匹配，但尚未确认恢复完成。"
                                 : recovery.differences.joined(separator: "\n"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxHeight: 230)
        .pluginSettingsCardBackground(.recessed)
        .accessibilityIdentifier("mac-settings.pending-recovery")
        .confirmationDialog("保留当前值并放弃本次恢复？", isPresented: Binding(
            get: { keepingID != nil }, set: { if !$0 { keepingID = nil } }
        ), titleVisibility: .visible) {
            Button("保留当前值", role: .destructive) {
                if let id = keepingID { controller.keepCurrentValues(id) }
                keepingID = nil
            }
            Button("取消", role: .cancel) { keepingID = nil }
        } message: {
            Text("这不会更改 macOS 设置，但会放弃此项目保留的恢复快照。")
        }
    }
}
