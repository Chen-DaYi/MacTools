import SwiftUI
import MacToolsPluginKit

struct DiskCleanDetailView: View {
    @ObservedObject var controller: DiskCleanController
    private let localization: PluginLocalization
    private let showsHeader: Bool
    private let contentPadding: CGFloat
    private let minimumContentHeight: CGFloat

    init(
        controller: DiskCleanController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        showsHeader: Bool = true,
        contentPadding: CGFloat = 20,
        minimumContentHeight: CGFloat = 420
    ) {
        self.controller = controller
        self.localization = localization
        self.showsHeader = showsHeader
        self.contentPadding = contentPadding
        self.minimumContentHeight = minimumContentHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if showsHeader {
                header
            }
            choiceControls
            actionBar
            scanLog
            statusSummary
            candidateList
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, minHeight: minimumContentHeight, alignment: .topLeading)
    }

    private var snapshot: DiskCleanControllerSnapshot {
        controller.snapshot
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localization.string("detail.title", defaultValue: "磁盘清理"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(snapshot.errorMessage ?? snapshot.subtitle(localization: localization))
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.medium))
                .foregroundStyle(snapshot.errorMessage == nil ? Color.secondary : Color.red)
        }
    }

    private var choiceControls: some View {
        HStack(spacing: 16) {
            ForEach(DiskCleanChoice.allCases) { choice in
                Toggle(
                    choice.title(localization: localization),
                    isOn: Binding(
                        get: { snapshot.selectedChoices.contains(choice) },
                        set: { controller.setChoice(choice, isSelected: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .disabled(snapshot.isBusy)
            }

            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                controller.scan()
            } label: {
                Label(localization.string("detail.action.scan", defaultValue: "扫描"), systemImage: "magnifyingglass")
            }
            .disabled(!snapshot.canScan)

            Button {
                controller.cleanSelected(candidateIDs: cleanableCandidateIDs)
            } label: {
                Label(localization.string("detail.action.clean", defaultValue: "清理"), systemImage: "trash")
            }
            .disabled(!snapshot.canClean)

            if snapshot.isBusy {
                Button {
                    controller.cancelCurrentOperation()
                } label: {
                    Label(localization.string("detail.action.stop", defaultValue: "停止"), systemImage: "xmark.circle")
                }
            }
        }
    }

    private var scanLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localization.string("detail.scanLog.title", defaultValue: "扫描日志"))
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                if snapshot.phase == .scanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if snapshot.scanLogEntries.isEmpty {
                            Text(localization.string("detail.scanLog.empty", defaultValue: "点击扫描后显示实时进度"))
                                .font(PluginSettingsTheme.Typography.secondaryLabel)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(snapshot.scanLogEntries) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 118, maxHeight: 160)
                .pluginSettingsCardBackground(.recessed)
                .onChange(of: snapshot.scanLogEntries.last?.id) {
                    guard let id = snapshot.scanLogEntries.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: DiskCleanScanLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: logIconName(entry.tone))
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(logColor(entry.tone))
                .frame(width: 14, height: 14)

            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let scanResult = snapshot.scanResult {
            HStack(spacing: 16) {
                summaryTile(
                    title: localization.string("detail.summary.cleanable", defaultValue: "可清理"),
                    value: itemCountText(scanResult.cleanableCandidates.count)
                )
                summaryTile(
                    title: localization.string("detail.summary.estimatedRelease", defaultValue: "预计释放"),
                    value: byteText(scanResult.cleanableSizeBytes)
                )
                summaryTile(
                    title: localization.string("detail.summary.protected", defaultValue: "已保护"),
                    value: itemCountText(scanResult.protectedCount)
                )
            }
        }

        if let executionResult = snapshot.executionResult {
            HStack(spacing: 16) {
                summaryTile(
                    title: localization.string("detail.summary.removed", defaultValue: "已删除"),
                    value: itemCountText(executionResult.removedCount)
                )
                summaryTile(
                    title: localization.string("detail.summary.skipped", defaultValue: "已跳过"),
                    value: itemCountText(executionResult.skippedCount)
                )
                summaryTile(
                    title: localization.string("detail.summary.failed", defaultValue: "失败"),
                    value: itemCountText(executionResult.failedCount)
                )
                summaryTile(
                    title: localization.string("detail.summary.released", defaultValue: "已释放"),
                    value: byteText(executionResult.reclaimedBytes)
                )
            }
        }
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    @ViewBuilder
    private var candidateList: some View {
        if let scanResult = snapshot.scanResult {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scanResult.candidates) { candidate in
                        candidateRow(candidate)
                        Divider()
                    }
                }
            }
            .overlay {
                if scanResult.candidates.isEmpty {
                    Text(localization.string("detail.candidates.empty", defaultValue: "没有发现可清理项目"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            EmptyView()
        }
    }

    private func candidateRow(_ candidate: DiskCleanCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.safety.isCleanable ? "checkmark.circle.fill" : "shield.fill")
                .foregroundStyle(candidate.safety.isCleanable ? Color.green : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Spacer(minLength: 12)
                    Text(byteText(candidate.sizeBytes))
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(.secondary)
                }

                Text(candidate.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(safetyText(candidate.safety))
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(candidate.safety.isCleanable ? Color.green : Color.secondary)
            }
        }
        .padding(.vertical, 9)
    }

    private var cleanableCandidateIDs: Set<DiskCleanCandidate.ID> {
        Set(snapshot.scanResult?.cleanableCandidates.map(\.id) ?? [])
    }

    private func safetyText(_ safety: DiskCleanSafetyStatus) -> String {
        switch safety {
        case .allowed:
            return localization.string("safety.allowed", defaultValue: "允许清理")
        case let .whitelisted(rule):
            return localization.format("safety.whitelisted", defaultValue: "白名单保护：%@", rule)
        case let .protected(reason):
            return localization.format("safety.protected", defaultValue: "敏感数据保护：%@", reason)
        case let .invalid(reason):
            return localization.format("safety.invalid", defaultValue: "路径安全保护：%@", reason)
        case let .requiresAdmin(reason):
            return localization.format("safety.requiresAdmin", defaultValue: "需要管理员权限：%@", reason)
        case let .inUse(processName):
            return localization.format("safety.inUse", defaultValue: "正在使用：%@", processName)
        }
    }

    private func itemCountText(_ count: Int) -> String {
        localization.format("item.count", defaultValue: "%d 项", count)
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func logIconName(_ tone: DiskCleanScanLogTone) -> String {
        switch tone {
        case .info:
            return "circle"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "shield.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func logColor(_ tone: DiskCleanScanLogTone) -> Color {
        switch tone {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
