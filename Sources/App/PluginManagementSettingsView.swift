import SwiftUI
import MacToolsPluginKit

struct PluginManagementSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    var appRelauncher: any AppRelaunching = AppRelauncher()

    @State private var alertMessage: String?
    @State private var activeOperationID: String?
    @State private var searchText: String = ""
    @State private var selectedFilter: PluginCategoryFilter = .all
    @State private var bulkUpdateProgressText: String?
    @State private var bulkUpdateProgressOpacity: Double = 0
    @State private var bulkUpdateProgressHideTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            header

            if pluginHost.pluginManagementItems.isEmpty {
                ContentUnavailableView(
                    AppL10n.plugins("plugin.marketplace.empty.title", defaultValue: "暂无插件"),
                    systemImage: "shippingbox",
                    description: Text(AppL10n.plugins(
                        "plugin.marketplace.empty.description",
                        defaultValue: "刷新插件列表后，可以在这里安装、更新和卸载。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PluginFilterBarView(
                    searchText: $searchText,
                    selectedFilter: $selectedFilter,
                    countsByFilter: countsByFilter
                )

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        AppL10n.plugins("plugin.filter.empty.title", defaultValue: "未找到匹配的插件"),
                        systemImage: "magnifyingglass",
                        description: Text(AppL10n.plugins("plugin.filter.empty.description", defaultValue: "尝试调整关键字或切换分类。"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredItems) { item in
                                PluginManagementRow(
                                    item: item,
                                    isBusy: activeOperationID == item.id
                                        || pluginHost.automaticPluginUpdateStatus.isUpdatingPlugin(id: item.id),
                                    isInteractionDisabled: activeOperationID != nil
                                        || pluginHost.automaticPluginUpdateStatus.isActive,
                                    onInstall: { runOperation(id: item.id) { try await pluginHost.installPluginFromCatalog(pluginID: item.id) } },
                                    onUpdate: { runOperation(id: item.id) { try await pluginHost.updatePluginFromCatalog(pluginID: item.id) } },
                                    onUninstall: { uninstall(item) },
                                    onRelaunch: { appRelauncher.relaunch() }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsStyle.contentBackground)
        .task {
            guard !pluginHost.automaticPluginUpdateStatus.isActive else {
                return
            }

            await pluginHost.refreshPluginCatalog()
        }
        .alert(
            AppL10n.plugins("plugin.marketplace.operationFailed.title", defaultValue: "插件操作失败"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            syncAutomaticBulkUpdateProgress(pluginHost.automaticPluginUpdateStatus)
        }
        .onChange(of: pluginHost.automaticPluginUpdateStatus) { _, status in
            syncAutomaticBulkUpdateProgress(status)
        }
    }

    private var filteredItems: [PluginManagementItem] {
        pluginHost.pluginManagementItems.filter {
            PluginListFilter.matches(managementItem: $0, query: searchText, filter: selectedFilter)
        }
    }

    private var countsByFilter: [PluginCategoryFilter: Int] {
        PluginListFilter.countsByFilter(
            managementItems: pluginHost.pluginManagementItems,
            query: searchText
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppL10n.plugins("plugin.marketplace.title", defaultValue: "市场"))
                    .font(PluginSettingsTheme.Typography.pageTitle)

                HStack(spacing: 8) {
                    Text(pluginHost.pluginCatalogStatus.title)
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)

                    if let lastUpdatedAt = pluginHost.pluginCatalogStatus.lastUpdatedAt {
                        Text(lastUpdatedAt, style: .time)
                            .font(PluginSettingsTheme.Typography.pageDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(pluginHost.pluginCatalogStatus.detailText)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(pluginHost.pluginCatalogStatus.errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowBulkUpdateControls {
                bulkUpdateProgressLabel

                Button {
                    runBulkUpdate()
                } label: {
                    PluginManagementActionLabel(
                        title: AppL10n.plugins("plugin.marketplace.updateAll", defaultValue: "全部更新"),
                        busyTitle: AppL10n.plugins("plugin.marketplace.updating", defaultValue: "更新中"),
                        isBusy: isBulkPluginUpdateBusy,
                        width: 74
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    activeOperationID != nil
                        || !hasAvailablePluginUpdates
                        || pluginHost.pluginCatalogStatus.isRefreshing
                        || pluginHost.automaticPluginUpdateStatus.isActive
                )
            }

            Button {
                runOperation(id: "catalog.refresh") {
                    await pluginHost.refreshPluginCatalog()
                }
            } label: {
                Label(AppL10n.plugins("plugin.marketplace.refresh", defaultValue: "刷新列表"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(
                activeOperationID != nil
                    || pluginHost.pluginCatalogStatus.isRefreshing
                    || pluginHost.automaticPluginUpdateStatus.isActive
            )
        }
    }

    private var hasAvailablePluginUpdates: Bool {
        pluginHost.pluginManagementItems.contains { $0.canUpdate }
    }

    private var shouldShowBulkUpdateControls: Bool {
        hasAvailablePluginUpdates || isBulkPluginUpdateBusy || bulkUpdateProgressText != nil
    }

    private var isBulkPluginUpdateBusy: Bool {
        activeOperationID == "catalog.updateAll"
            || pluginHost.automaticPluginUpdateStatus.phase == .updating
    }

    @ViewBuilder
    private var bulkUpdateProgressLabel: some View {
        if let bulkUpdateProgressText {
            Text(bulkUpdateProgressText)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(bulkUpdateProgressOpacity)
        }
    }

    private func runOperation(id: String, _ operation: @escaping () async throws -> Void) {
        guard activeOperationID == nil,
              !pluginHost.automaticPluginUpdateStatus.isActive
        else {
            return
        }

        activeOperationID = id
        hideBulkUpdateProgressText()

        Task {
            do {
                try await operation()
            } catch {
                alertMessage = error.localizedDescription
            }

            activeOperationID = nil
        }
    }

    private func runBulkUpdate() {
        guard activeOperationID == nil,
              !pluginHost.automaticPluginUpdateStatus.isActive
        else {
            return
        }

        activeOperationID = "catalog.updateAll"
        bulkUpdateProgressHideTask?.cancel()
        showBulkUpdateProgressText(
            AppL10n.pluginsFormat(
                "plugin.marketplace.bulkUpdate.progressFormat",
                defaultValue: "已完成 %d/%d",
                0,
                availablePluginUpdateCount
            )
        )

        Task {
            do {
                try await pluginHost.updateAvailablePluginsFromCatalog { progress in
                    showBulkUpdateProgressText(
                        AppL10n.pluginsFormat(
                            "plugin.marketplace.bulkUpdate.progressFormat",
                            defaultValue: "已完成 %d/%d",
                            progress.completedCount,
                            progress.totalCount
                        )
                    )
                }

                activeOperationID = nil
                showBulkUpdateProgressText(
                    AppL10n.plugins("plugin.marketplace.bulkUpdate.completed", defaultValue: "更新完成")
                )
                scheduleBulkUpdateProgressFadeOut()
            } catch {
                activeOperationID = nil
                alertMessage = error.localizedDescription
                hideBulkUpdateProgressText()
            }
        }
    }

    private func showBulkUpdateProgressText(_ text: String) {
        bulkUpdateProgressHideTask?.cancel()
        bulkUpdateProgressText = text

        withAnimation(.easeOut(duration: 0.15)) {
            bulkUpdateProgressOpacity = 1
        }
    }

    private func scheduleBulkUpdateProgressFadeOut() {
        bulkUpdateProgressHideTask?.cancel()
        bulkUpdateProgressHideTask = Task {
            withAnimation(.easeOut(duration: 2)) {
                bulkUpdateProgressOpacity = 0
            }

            try? await Task.sleep(for: .seconds(2))

            guard !Task.isCancelled else {
                return
            }

            bulkUpdateProgressText = nil
        }
    }

    private func syncAutomaticBulkUpdateProgress(_ status: PluginAutomaticUpdateStatus) {
        switch status.phase {
        case .updating:
            guard !status.pluginIDs.isEmpty else {
                return
            }

            showBulkUpdateProgressText(
                status.message
                    ?? AppL10n.pluginsFormat(
                        "plugin.marketplace.bulkUpdate.progressFormat",
                        defaultValue: "已完成 %d/%d",
                        0,
                        status.pluginIDs.count
                    )
            )
        case .completed:
            guard bulkUpdateProgressText != nil, !status.pluginIDs.isEmpty else {
                return
            }

            showBulkUpdateProgressText(
                AppL10n.plugins("plugin.marketplace.bulkUpdate.completed", defaultValue: "更新完成")
            )
            scheduleBulkUpdateProgressFadeOut()
        case .failed:
            hideBulkUpdateProgressText()
        case .idle, .checking:
            break
        }
    }

    private func hideBulkUpdateProgressText() {
        bulkUpdateProgressHideTask?.cancel()

        withAnimation(.easeOut(duration: 0.2)) {
            bulkUpdateProgressOpacity = 0
        }

        bulkUpdateProgressText = nil
    }

    private func uninstall(_ item: PluginManagementItem) {
        guard activeOperationID == nil else {
            return
        }

        do {
            try pluginHost.uninstallDynamicPlugin(pluginID: item.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private var availablePluginUpdateCount: Int {
        pluginHost.pluginManagementItems.filter(\.canUpdate).count
    }
}

private struct PluginManagementRow: View {
    let item: PluginManagementItem
    let isBusy: Bool
    let isInteractionDisabled: Bool
    let onInstall: () -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor.opacity(0.14))

                Image(systemName: statusImageName)
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: PluginSettingsTheme.Size.metricIcon, height: PluginSettingsTheme.Size.metricIcon)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    PluginReleaseChannelBadge(releaseChannel: item.releaseChannel)

                    Text(item.version)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.secondary)
                }

                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let visibleStatusText {
                Text(visibleStatusText)
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 58, alignment: .trailing)
            }

            actionButtons
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.host)
    }

    private var detail: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.detailText)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            if item.requiresRelaunchAction {
                Button(AppL10n.plugins("plugin.marketplace.relaunchNow", defaultValue: "立即重启"), action: onRelaunch)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .buttonStyle(.link)
                    .disabled(isInteractionDisabled)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.canInstall {
            Button(action: onInstall) {
                PluginManagementActionLabel(
                    title: AppL10n.plugins("plugin.marketplace.install", defaultValue: "安装"),
                    busyTitle: AppL10n.plugins("plugin.marketplace.installing", defaultValue: "安装中"),
                    isBusy: isBusy,
                    width: actionButtonLabelWidth
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInteractionDisabled)
        }

        if item.canUpdate {
            Button(action: onUpdate) {
                PluginManagementActionLabel(
                    title: AppL10n.plugins("plugin.marketplace.update", defaultValue: "更新"),
                    busyTitle: AppL10n.plugins("plugin.marketplace.updating", defaultValue: "更新中"),
                    isBusy: isBusy,
                    width: actionButtonLabelWidth
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInteractionDisabled)
        }

        if item.canUninstall {
            Button(role: .destructive, action: onUninstall) {
                Text(AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"))
                    .frame(width: actionButtonLabelWidth)
            }
            .buttonStyle(.bordered)
            .disabled(isInteractionDisabled)
        }
    }

    private var visibleStatusText: String? {
        switch item.state {
        case .available, .enabled, .disabled:
            return nil
        case .localDevelopment, .updateAvailable, .restartRequired, .failed, .incompatible, .revoked:
            return item.statusText
        }
    }

    private var actionButtonLabelWidth: CGFloat {
        64
    }

    private var statusColor: Color {
        switch item.state {
        case .available, .localDevelopment:
            return .blue
        case .enabled:
            return .green
        case .disabled:
            return .secondary
        case .updateAvailable, .restartRequired:
            return .accentColor
        case .failed, .incompatible, .revoked:
            return .orange
        }
    }

    private var statusImageName: String {
        switch item.state {
        case .available:
            return "arrow.down.circle.fill"
        case .localDevelopment:
            return "hammer.circle.fill"
        case .enabled:
            return "checkmark.seal.fill"
        case .disabled:
            return "pause.circle"
        case .updateAvailable:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .restartRequired:
            return "restart.circle.fill"
        case .failed, .incompatible, .revoked:
            return "exclamationmark.triangle.fill"
        }
    }
}

private extension PluginManagementItem {
    var requiresRelaunchAction: Bool {
        if case .restartRequired = state {
            return true
        }

        return false
    }
}

private struct PluginManagementActionLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            }

            Text(isBusy ? busyTitle : title)
        }
        .frame(width: width)
    }
}
