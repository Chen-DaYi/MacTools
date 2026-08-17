import MacToolsPluginKit
import SwiftUI

enum AppleShortcutsSettingsFilter: String, CaseIterable, Identifiable {
    case all
    case enabled

    var id: String { rawValue }
}

enum AppleShortcutsSource: Hashable {
    case all
    case missing
    case folder(UUID)
}

struct AppleShortcutsDisplayRow: Identifiable {
    let id: UUID
    let name: String
    let item: AppleShortcutItem?
    let isMissing: Bool
}

enum AppleShortcutsSettingsFiltering {
    static func visibleRows(
        from rows: [AppleShortcutsDisplayRow],
        source: AppleShortcutsSource,
        filter: AppleShortcutsSettingsFilter,
        searchText: String,
        enabledIDs: Set<UUID>,
        folderIDsByShortcut: [UUID: Set<UUID>]
    ) -> [AppleShortcutsDisplayRow] {
        rows.filter { row in
            let matchesSource: Bool
            switch source {
            case .all:
                matchesSource = true
            case .missing:
                matchesSource = row.isMissing
            case let .folder(id):
                matchesSource = folderIDsByShortcut[row.id, default: []].contains(id)
            }
            let matchesFilter = filter == .all || enabledIDs.contains(row.id)
            let matchesSearch = searchText.isEmpty
                || row.name.localizedCaseInsensitiveContains(searchText)
                || row.id.uuidString.localizedCaseInsensitiveContains(searchText)
            return matchesSource && matchesFilter && matchesSearch
        }
    }
}

enum AppleShortcutsBatchSelection {
    static func selectedRows(
        selectedIDs: Set<UUID>,
        visibleRows: [AppleShortcutsDisplayRow]
    ) -> [AppleShortcutsDisplayRow] {
        visibleRows.filter { selectedIDs.contains($0.id) }
    }

    static func retainingVisibleIDs(
        _ selectedIDs: Set<UUID>,
        visibleRows: [AppleShortcutsDisplayRow]
    ) -> Set<UUID> {
        selectedIDs.intersection(Set(visibleRows.map(\.id)))
    }

    static func enableItems(
        from selectedRows: [AppleShortcutsDisplayRow],
        enabledIDs: Set<UUID>
    ) -> [AppleShortcutItem] {
        selectedRows.compactMap { row in
            guard !row.isMissing,
                  !enabledIDs.contains(row.id) else {
                return nil
            }
            return row.item
        }
    }

    static func disableItems(
        from selectedRows: [AppleShortcutsDisplayRow],
        enabledIDs: Set<UUID>,
        recordsByID: [UUID: AppleShortcutTrackedRecord]
    ) -> [AppleShortcutItem] {
        selectedRows.compactMap { row in
            guard enabledIDs.contains(row.id) else { return nil }
            return item(for: row, recordsByID: recordsByID)
        }
    }

    static func item(
        for row: AppleShortcutsDisplayRow,
        recordsByID: [UUID: AppleShortcutTrackedRecord]
    ) -> AppleShortcutItem? {
        row.item ?? recordsByID[row.id].map {
            AppleShortcutItem(
                id: $0.id,
                name: $0.lastKnownName,
                folderIDs: $0.lastKnownFolderIDs
            )
        }
    }
}

enum AppleShortcutsSettingsFormatting {
    static func joinedFolderNames(
        _ names: [String],
        locale: Locale = PluginRuntimeLocalization.locale
    ) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
}

enum AppleShortcutsSettingsRunDisposition: Equatable {
    case runImmediately
    case requireConfirmation

    static func resolve(policy: AppleShortcutPolicy) -> Self {
        policy.requiresConfirmation ? .requireConfirmation : .runImmediately
    }

    static func route(
        policy: AppleShortcutPolicy,
        requestConfirmation: () -> Void,
        run: () -> Void
    ) {
        switch resolve(policy: policy) {
        case .runImmediately:
            run()
        case .requireConfirmation:
            requestConfirmation()
        }
    }
}

private struct PendingFolderSync: Identifiable {
    let folder: AppleShortcutFolder
    let enable: Bool
    let members: [AppleShortcutItem]

    var id: UUID { folder.id }
}

private struct AppleShortcutsFolderRow: Identifiable {
    let folder: AppleShortcutFolder
    let isMissing: Bool
    var id: UUID { folder.id }
}

private enum AppleShortcutsBatchOperation {
    case enable
    case disable
}

private struct PendingAppleShortcutsBatchChange: Identifiable {
    let operation: AppleShortcutsBatchOperation
    let items: [AppleShortcutItem]
    let id = UUID()
}

private enum AppleShortcutsSettingsAlert: Identifiable {
    case testRun(AppleShortcutsDisplayRow)
    case batchChange(PendingAppleShortcutsBatchChange)

    var id: String {
        switch self {
        case let .testRun(row): "test-run-\(row.id.uuidString)"
        case let .batchChange(change): "batch-change-\(change.id.uuidString)"
        }
    }
}

struct AppleShortcutsSettingsView: View {
    let plugin: AppleShortcutsPlugin
    @ObservedObject private var controller: AppleShortcutsController
    @ObservedObject private var store: AppleShortcutsStore
    @ObservedObject private var executionStore: AppleShortcutsExecutionStore

    @State private var searchText = ""
    @State private var filter: AppleShortcutsSettingsFilter = .all
    @State private var source: AppleShortcutsSource = .all
    @State private var selectedID: UUID?
    @State private var isBatchSelecting = false
    @State private var batchSelectedIDs = Set<UUID>()
    @State private var pendingFolderSync: PendingFolderSync?
    @State private var pendingAlert: AppleShortcutsSettingsAlert?

    init(plugin: AppleShortcutsPlugin) {
        self.plugin = plugin
        controller = plugin.controller
        store = plugin.store
        executionStore = plugin.controller.executionStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            toolbar
            statusContent
            HSplitView {
                sourceSidebar
                    .frame(minWidth: 155, idealWidth: 190, maxWidth: 230)
                shortcutList
                    .frame(minWidth: 260, idealWidth: 340)
                detailPane
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
            .pluginSettingsCardBackground(.standard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $pendingFolderSync) { pending in
            AppleShortcutsFolderSyncReviewView(
                plugin: plugin,
                pending: pending,
                onConfirm: { applyFolderSync(pending) },
                onCancel: { pendingFolderSync = nil }
            )
        }
        .alert(item: $pendingAlert) { alert in
            switch alert {
            case let .testRun(row):
                Alert(
                    title: Text(plugin.localizedFormat(
                        "settings.run.confirm.title",
                        defaultValue: "运行“%@”？",
                        row.name
                    )),
                    message: Text(plugin.localized(
                        "settings.run.confirm.message",
                        defaultValue: "此快捷指令将通过 Apple“快捷指令”运行，并可能访问其他应用或数据。"
                    )),
                    primaryButton: .default(Text(plugin.localized(
                        "settings.run.confirm.button",
                        defaultValue: "运行"
                    ))) {
                        run(row)
                    },
                    secondaryButton: .cancel(Text(plugin.localized(
                        "common.cancel",
                        defaultValue: "取消"
                    )))
                )
            case let .batchChange(change):
                Alert(
                    title: Text(batchConfirmationTitle(for: change)),
                    message: Text(batchConfirmationMessage(for: change)),
                    primaryButton: batchConfirmationButton(for: change),
                    secondaryButton: .cancel(Text(plugin.localized(
                        "common.cancel",
                        defaultValue: "取消"
                    )))
                )
            }
        }
        .onAppear {
            controller.refreshIfNeeded()
            selectFirstVisibleIfNeeded()
        }
        .onChange(of: visibleRows.map(\.id)) { _, _ in
            selectFirstVisibleIfNeeded()
            keepBatchSelectionVisible()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField(
                plugin.localized("settings.search", defaultValue: "搜索快捷指令"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160, idealWidth: 260, maxWidth: 360)

            Picker(plugin.localized("settings.filter", defaultValue: "筛选"), selection: $filter) {
                Text(plugin.localized("settings.filter.all", defaultValue: "全部"))
                    .tag(AppleShortcutsSettingsFilter.all)
                Text(plugin.localized("settings.filter.enabled", defaultValue: "已启用"))
                    .tag(AppleShortcutsSettingsFilter.enabled)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)

            Spacer()

            Text(plugin.localizedFormat(
                "settings.counts.format",
                defaultValue: "%1$lld / %2$lld",
                Int64(controller.snapshot.discovery.shortcuts.count),
                Int64(store.trackedRecords.count)
            ))
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
                .help(plugin.localized("settings.counts", defaultValue: "已发现 / 已启用"))

            Button {
                controller.refresh(force: true)
            } label: {
                Label(
                    controller.snapshot.isRefreshing
                        ? plugin.localized("settings.refreshing", defaultValue: "正在刷新")
                        : plugin.localized("settings.refresh", defaultValue: "刷新"),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.snapshot.isRefreshing)
            .accessibilityIdentifier("apple-shortcuts-refresh")

            Button {
                if isBatchSelecting {
                    finishBatchSelection()
                } else {
                    isBatchSelecting = true
                }
            } label: {
                Label(
                    isBatchSelecting
                        ? plugin.localized("batch.done", defaultValue: "完成")
                        : plugin.localized("batch.select", defaultValue: "选择"),
                    systemImage: isBatchSelecting ? "checkmark" : "checkmark.circle"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(visibleRows.isEmpty && !isBatchSelecting)
            .accessibilityIdentifier("apple-shortcuts-batch-selection")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let loadError = store.loadError {
            statusBanner(
                loadError == "invalid-apple-shortcuts-settings"
                    ? plugin.localized(
                        "settings.invalid",
                        defaultValue: "无法读取设置；原始数据已保留。"
                    ) : loadError,
                image: "exclamationmark.triangle.fill",
                color: .red
            )
        } else if let error = controller.snapshot.errorMessage {
            statusBanner(error, image: "exclamationmark.triangle.fill", color: .orange)
        } else if let message = controller.snapshot.operationMessage {
            statusBanner(message, image: "checkmark.circle.fill", color: .green)
        }
    }

    private var sourceSidebar: some View {
        List(selection: $source) {
            Label(plugin.localized("source.all", defaultValue: "全部快捷指令"), systemImage: "square.stack.3d.up")
                .tag(AppleShortcutsSource.all)
                .accessibilityIdentifier("apple-shortcuts-source-all")

            if !missingRows.isEmpty {
                Label(plugin.localized("source.missing", defaultValue: "未找到"), systemImage: "questionmark.folder")
                    .tag(AppleShortcutsSource.missing)
                    .accessibilityIdentifier("apple-shortcuts-source-missing")
            }

            Section(plugin.localized("source.folders", defaultValue: "文件夹")) {
                ForEach(folderRows) { row in
                    HStack {
                        Label(row.folder.name, systemImage: row.isMissing ? "questionmark.folder" : "folder")
                        Spacer()
                        if store.isFolderSynced(row.id) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                        }
                        if row.isMissing || controller.snapshot.discovery.failedFolderIDs.contains(row.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(AppleShortcutsSource.folder(row.id))
                    .accessibilityIdentifier("apple-shortcuts-source-folder-\(row.id.uuidString)")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var shortcutList: some View {
        VStack(spacing: 0) {
            if case let .folder(folderID) = source, let folder = folderForDisplay(folderID) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .lineLimit(1)
                        Text(plugin.localized(
                            isFolderMissing(folderID)
                                ? "folder.sync.missing.subtitle" : "folder.sync.subtitle",
                            defaultValue: isFolderMissing(folderID)
                                ? "文件夹暂时未找到；已保留上次的成员"
                                : "自动启用此文件夹以后新增的快捷指令"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                    Button(store.isFolderSynced(folder.id)
                        ? plugin.localized("folder.sync.stop", defaultValue: "停止同步")
                        : plugin.localized("folder.sync.start", defaultValue: "保持同步")) {
                        pendingFolderSync = PendingFolderSync(
                            folder: folder,
                            enable: !store.isFolderSynced(folder.id),
                            members: membersForFolder(folder.id)
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        !store.isFolderSynced(folder.id)
                            && controller.snapshot.discovery.failedFolderIDs.contains(folder.id)
                    )
                    .accessibilityIdentifier("apple-shortcuts-folder-sync")
                }
                .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                Divider()
            }

            if isBatchSelecting {
                batchSelectionControls
                Divider()
            }

            if controller.snapshot.isRefreshing && controller.snapshot.lastSuccessfulRefresh == nil {
                ContentUnavailableView {
                    Label(plugin.localized("settings.loading", defaultValue: "正在读取快捷指令"), systemImage: "arrow.clockwise")
                } description: {
                    ProgressView()
                }
            } else if visibleRows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyImage,
                    description: Text(emptyDescription)
                )
            } else {
                List(visibleRows, selection: $selectedID) { row in
                    shortcutRow(row)
                        .tag(row.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private func shortcutRow(_ row: AppleShortcutsDisplayRow) -> some View {
        HStack(spacing: 10) {
            if isBatchSelecting {
                Button {
                    toggleBatchSelection(for: row.id)
                } label: {
                    Image(systemName: batchSelectedIDs.contains(row.id)
                        ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(batchSelectedIDs.contains(row.id) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(plugin.localized(
                    "batch.selection.accessibility",
                    defaultValue: "选择快捷指令"
                ))
                .accessibilityIdentifier("apple-shortcuts-batch-select-\(row.id.uuidString)")
            }
            Image(systemName: row.isMissing ? "questionmark.square.dashed" : "square.stack.3d.up.fill")
                .foregroundStyle(row.isMissing ? Color.secondary : Color.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                if row.isMissing {
                    Text(plugin.localized("shortcut.missing", defaultValue: "在 Apple“快捷指令”中未找到"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                } else if controller.isRunning(row.id) {
                    Text(plugin.localized("run.running", defaultValue: "正在运行"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                } else if let context = sourceContext(for: row).appleShortcutsNilIfEmpty {
                    Text(context)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !isBatchSelecting {
                Toggle("", isOn: Binding(
                    get: { store.isEnabled(row.id) },
                    set: { enabled in
                        if enabled, let item = row.item {
                            present(store.setShortcutEnabled(true, item: item))
                        } else if let item = itemForBatchChange(from: row) {
                            present(store.setShortcutEnabled(false, item: item))
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(row.isMissing && !store.isEnabled(row.id))
                .accessibilityLabel(plugin.localized("shortcut.enable", defaultValue: "启用快捷指令"))
                .accessibilityIdentifier("apple-shortcuts-enable-\(row.id.uuidString)")
            }
        }
        .padding(.vertical, 3)
    }

    private var batchSelectionControls: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(plugin.localizedFormat(
                "batch.selected.format",
                defaultValue: "%lld 已选择",
                Int64(batchSelectedIDs.count)
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button(plugin.localized("batch.select.all.visible", defaultValue: "选择全部可见项")) {
                    batchSelectedIDs = Set(visibleRows.map(\.id))
                }
                .disabled(visibleRows.isEmpty)

                Button(plugin.localized("batch.clear", defaultValue: "清除选择")) {
                    batchSelectedIDs.removeAll()
                }
                .disabled(batchSelectedIDs.isEmpty)

                Divider()

                Button(batchActionTitle(.enable, count: batchEnableItems.count)) {
                    requestBatchChange(.enable, items: batchEnableItems)
                }
                .disabled(batchEnableItems.isEmpty)
                .accessibilityIdentifier("apple-shortcuts-batch-enable")

                Button(batchActionTitle(.disable, count: batchDisableItems.count), role: .destructive) {
                    requestBatchChange(.disable, items: batchDisableItems)
                }
                .disabled(batchDisableItems.isEmpty)
                .accessibilityIdentifier("apple-shortcuts-batch-disable")
            } label: {
                Label(
                    plugin.localized("batch.actions", defaultValue: "批量操作"),
                    systemImage: "ellipsis.circle"
                )
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityIdentifier("apple-shortcuts-batch-actions")
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedID,
           let row = allRows.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Text(row.name)
                                .font(PluginSettingsTheme.Typography.pageTitle)
                                .textSelection(.enabled)
                            Text(row.id.uuidString.lowercased())
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(sourceContext(for: row))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.isMissing {
                            Label(plugin.localized("shortcut.missing.badge", defaultValue: "未找到"), systemImage: "questionmark.circle")
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.orange)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            plugin.localized("detail.sources", defaultValue: "来源"),
                            systemImage: "folder"
                        )
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        ForEach(folderNames(for: row), id: \.self) { name in
                            Label(name, systemImage: "folder")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                        }
                        if store.isExplicitlyEnabled(row.id) {
                            Label(
                                plugin.localized("source.explicit", defaultValue: "单独启用"),
                                systemImage: "checkmark.circle"
                            )
                            .font(PluginSettingsTheme.Typography.rowDescription)
                        }
                        if folderNames(for: row).isEmpty && !store.isExplicitlyEnabled(row.id) {
                            Text(plugin.localized("source.none", defaultValue: "没有启用来源"))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { store.policy(for: row.id).requiresConfirmation },
                        set: { present(store.setRequiresConfirmation($0, for: row.id)) }
                    )) {
                        settingLabel(
                            plugin.localized("policy.confirm.title", defaultValue: "运行前确认"),
                            description: plugin.localized("policy.confirm.description", defaultValue: "从 MacTools 操作界面运行前要求确认。")
                        )
                    }
                    .toggleStyle(.switch)
                    .disabled(!store.isEnabled(row.id))
                    .accessibilityIdentifier("apple-shortcuts-require-confirmation")

                    Toggle(isOn: Binding(
                        get: { store.policy(for: row.id).allowsRunLink },
                        set: { present(store.setAllowsRunLink($0, for: row.id)) }
                    )) {
                        settingLabel(
                            plugin.localized("policy.runlink.title", defaultValue: "允许 Run Link"),
                            description: plugin.localized("policy.runlink.description", defaultValue: "允许外部链接触发；每次仍需确认。")
                        )
                    }
                    .toggleStyle(.switch)
                    .disabled(!store.isEnabled(row.id))
                    .accessibilityIdentifier("apple-shortcuts-allow-run-link")

                    Divider()

                    HStack {
                        if controller.isRunning(row.id) {
                            Button(role: .cancel) {
                                controller.cancelExecution(shortcutID: row.id)
                            } label: {
                                Label(plugin.localized("run.stop", defaultValue: "停止"), systemImage: "stop.fill")
                            }
                            .accessibilityIdentifier("apple-shortcuts-stop")
                        } else {
                            Button {
                                requestRun(row)
                            } label: {
                                Label(plugin.localized("run.test", defaultValue: "测试运行"), systemImage: "play.fill")
                            }
                            .disabled(row.isMissing || !store.isEnabled(row.id))
                            .accessibilityIdentifier("apple-shortcuts-test-run")
                        }

                        Button {
                            controller.openInShortcuts(row.id)
                        } label: {
                            Label(plugin.localized("view.open", defaultValue: "在“快捷指令”中打开"), systemImage: "arrow.up.forward.app")
                        }
                        .disabled(row.isMissing)
                        .accessibilityIdentifier("apple-shortcuts-open")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let record = executionStore.record(for: row.id) {
                        executionResult(record)
                    }
                }
                .padding(PluginSettingsTheme.Spacing.rowHorizontal)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                plugin.localized("detail.empty", defaultValue: "选择一个快捷指令"),
                systemImage: "square.stack.3d.up"
            )
        }
    }

    private func settingLabel(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(title).font(PluginSettingsTheme.Typography.rowTitle)
            Text(description)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
    }

    private func executionResult(_ record: AppleShortcutRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(runStatusTitle(record.status), systemImage: runStatusImage(record.status))
                .font(PluginSettingsTheme.Typography.sectionTitle)
            let capturedOutput = record.status == .failed
                ? (record.standardError.appleShortcutsNilIfEmpty
                    ?? record.standardOutput.appleShortcutsNilIfEmpty)
                : (record.standardOutput.appleShortcutsNilIfEmpty
                    ?? record.standardError.appleShortcutsNilIfEmpty)
            let output = capturedOutput ?? record.message
            if let output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .pluginSettingsCardBackground(.recessed)
            }
            if record.outputWasTruncated {
                Text(plugin.localized("run.truncated", defaultValue: "输出过长，已截断。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allRows: [AppleShortcutsDisplayRow] {
        let discovered = controller.snapshot.discovery.shortcuts.map {
            AppleShortcutsDisplayRow(id: $0.id, name: $0.name, item: $0, isMissing: false)
        }
        return (discovered + missingRows).sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }

    private var missingRows: [AppleShortcutsDisplayRow] {
        let discoveredIDs = controller.snapshot.shortcutIDs
        return store.trackedRecords.filter { !discoveredIDs.contains($0.id) }.map {
            AppleShortcutsDisplayRow(
                id: $0.id,
                name: plugin.displayName(for: $0),
                item: nil,
                isMissing: true
            )
        }
    }

    private var folderRows: [AppleShortcutsFolderRow] {
        let discovered = controller.snapshot.discovery.folders.map {
            AppleShortcutsFolderRow(folder: $0, isMissing: false)
        }
        let discoveredIDs = Set(discovered.map(\.id))
        let missing = store.state.syncedFolders.values
            .filter { !discoveredIDs.contains($0.id) }
            .map {
                AppleShortcutsFolderRow(
                    folder: AppleShortcutFolder(
                        id: $0.id,
                        name: $0.lastKnownName.appleShortcutsNilIfEmpty
                            ?? plugin.localized("folder.unknown", defaultValue: "未找到的文件夹")
                    ),
                    isMissing: true
                )
            }
        return (discovered + missing).sorted {
            let comparison = $0.folder.name.localizedStandardCompare($1.folder.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }

    private func folderForDisplay(_ id: UUID) -> AppleShortcutFolder? {
        folderRows.first { $0.id == id }?.folder
    }

    private func isFolderMissing(_ id: UUID) -> Bool {
        folderRows.first { $0.id == id }?.isMissing == true
    }

    private func folderIDs(for row: AppleShortcutsDisplayRow) -> Set<UUID> {
        var ids = row.item?.folderIDs ?? []
        if let record = store.record(id: row.id) {
            ids.formUnion(record.lastKnownFolderIDs)
        }
        for folder in store.state.syncedFolders.values where folder.memberIDs.contains(row.id) {
            ids.insert(folder.id)
        }
        return ids
    }

    private func folderNames(for row: AppleShortcutsDisplayRow) -> [String] {
        folderIDs(for: row).compactMap { folderForDisplay($0)?.name }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func sourceContext(for row: AppleShortcutsDisplayRow) -> String {
        var parts: [String] = []
        if store.isExplicitlyEnabled(row.id) {
            parts.append(plugin.localized("source.explicit", defaultValue: "单独启用"))
        }
        let names = folderNames(for: row)
        if !names.isEmpty {
            parts.append(plugin.localizedFormat(
                "source.folders.format",
                defaultValue: "文件夹：%@",
                AppleShortcutsSettingsFormatting.joinedFolderNames(names)
            ))
        }
        return parts.joined(separator: " · ")
    }

    private var visibleRows: [AppleShortcutsDisplayRow] {
        let rows = allRows
        return AppleShortcutsSettingsFiltering.visibleRows(
            from: rows,
            source: source,
            filter: filter,
            searchText: searchText,
            enabledIDs: store.state.effectiveEnabledIDs,
            folderIDsByShortcut: Dictionary(uniqueKeysWithValues: rows.map {
                ($0.id, folderIDs(for: $0))
            })
        )
    }

    private var batchSelectedRows: [AppleShortcutsDisplayRow] {
        AppleShortcutsBatchSelection.selectedRows(
            selectedIDs: batchSelectedIDs,
            visibleRows: visibleRows
        )
    }

    private var batchEnableItems: [AppleShortcutItem] {
        AppleShortcutsBatchSelection.enableItems(
            from: batchSelectedRows,
            enabledIDs: store.state.effectiveEnabledIDs
        )
    }

    private var batchDisableItems: [AppleShortcutItem] {
        AppleShortcutsBatchSelection.disableItems(
            from: batchSelectedRows,
            enabledIDs: store.state.effectiveEnabledIDs,
            recordsByID: store.state.trackedRecords
        )
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return plugin.localized("empty.search", defaultValue: "没有匹配项") }
        if filter == .enabled { return plugin.localized("empty.enabled", defaultValue: "尚未启用快捷指令") }
        if source == .missing { return plugin.localized("empty.missing", defaultValue: "没有未找到的快捷指令") }
        return plugin.localized("empty.library", defaultValue: "没有快捷指令")
    }

    private var emptyImage: String { searchText.isEmpty ? "square.stack.3d.up" : "magnifyingglass" }

    private var emptyDescription: String {
        searchText.isEmpty
            ? plugin.localized("empty.library.description", defaultValue: "请先在 Apple“快捷指令”中创建快捷指令，然后刷新。")
            : plugin.localized("empty.search.description", defaultValue: "请尝试其他搜索内容。")
    }

    private func itemForBatchChange(from row: AppleShortcutsDisplayRow) -> AppleShortcutItem? {
        AppleShortcutsBatchSelection.item(for: row, recordsByID: store.state.trackedRecords)
    }

    private func toggleBatchSelection(for id: UUID) {
        if batchSelectedIDs.contains(id) {
            batchSelectedIDs.remove(id)
        } else {
            batchSelectedIDs.insert(id)
        }
    }

    private func keepBatchSelectionVisible() {
        batchSelectedIDs = AppleShortcutsBatchSelection.retainingVisibleIDs(
            batchSelectedIDs,
            visibleRows: visibleRows
        )
    }

    private func finishBatchSelection() {
        isBatchSelecting = false
        batchSelectedIDs.removeAll()
    }

    private func requestBatchChange(
        _ operation: AppleShortcutsBatchOperation,
        items: [AppleShortcutItem]
    ) {
        guard !items.isEmpty else { return }
        pendingAlert = .batchChange(PendingAppleShortcutsBatchChange(operation: operation, items: items))
    }

    private func applyBatchChange(_ change: PendingAppleShortcutsBatchChange) {
        let result = store.setShortcutsEnabled(change.operation == .enable, items: change.items)
        if case .success = result {
            batchSelectedIDs.subtract(Set(change.items.map(\.id)))
        }
        present(result)
        pendingAlert = nil
    }

    private func batchActionTitle(
        _ operation: AppleShortcutsBatchOperation,
        count: Int
    ) -> String {
        switch operation {
        case .enable:
            return plugin.localizedFormat(
                "batch.enable.format",
                defaultValue: "启用 (%lld)",
                Int64(count)
            )
        case .disable:
            return plugin.localizedFormat(
                "batch.disable.format",
                defaultValue: "停用 (%lld)",
                Int64(count)
            )
        }
    }

    private func batchConfirmationTitle(for change: PendingAppleShortcutsBatchChange) -> String {
        switch change.operation {
        case .enable:
            return plugin.localizedFormat(
                "batch.enable.confirm.title.format",
                defaultValue: "启用 %lld 个快捷指令？",
                Int64(change.items.count)
            )
        case .disable:
            return plugin.localizedFormat(
                "batch.disable.confirm.title.format",
                defaultValue: "停用 %lld 个快捷指令？",
                Int64(change.items.count)
            )
        }
    }

    private func batchConfirmationMessage(for change: PendingAppleShortcutsBatchChange) -> String {
        switch change.operation {
        case .enable:
            return plugin.localized(
                "batch.enable.confirm.message",
                defaultValue: "启用后，这些快捷指令会出现在 MacTools 中。不会启用 Run Link。"
            )
        case .disable:
            return plugin.localized(
                "batch.disable.confirm.message",
                defaultValue: "停用后，这些快捷指令将不再出现在 MacTools 中，其 MacTools 运行设置也会移除。"
            )
        }
    }

    private func batchConfirmationButton(for change: PendingAppleShortcutsBatchChange) -> Alert.Button {
        switch change.operation {
        case .enable:
            return .default(Text(batchActionTitle(.enable, count: change.items.count))) {
                applyBatchChange(change)
            }
        case .disable:
            return .destructive(Text(batchActionTitle(.disable, count: change.items.count))) {
                applyBatchChange(change)
            }
        }
    }

    private func statusBanner(_ text: String, image: String, color: Color) -> some View {
        Label(text, systemImage: image)
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            .pluginSettingsCardBackground(.standard)
    }

    private func applyFolderSync(_ pending: PendingFolderSync) {
        present(store.setFolderSynced(
            pending.enable,
            folder: pending.folder,
            members: pending.members
        ))
        pendingFolderSync = nil
    }

    private func membersForFolder(_ folderID: UUID) -> [AppleShortcutItem] {
        controller.snapshot.discovery.shortcuts.filter {
            $0.folderIDs.contains(folderID)
        }
    }

    private func run(_ row: AppleShortcutsDisplayRow) {
        guard store.isEnabled(row.id),
              controller.snapshot.shortcutIDs.contains(row.id) else { return }
        switch controller.startExecution(shortcutID: row.id, name: row.name) {
        case let .success(run):
            Task { @MainActor in
                _ = await controller.waitForExecution(run, shortcutID: row.id)
            }
        case let .failure(error):
            controller.presentExecutionStartError(error)
        }
    }

    private func requestRun(_ row: AppleShortcutsDisplayRow) {
        AppleShortcutsSettingsRunDisposition.route(
            policy: store.policy(for: row.id),
            requestConfirmation: { pendingAlert = .testRun(row) },
            run: { run(row) }
        )
    }

    private func present(_ result: Result<Void, AppleShortcutsStoreError>) {
        if case let .failure(error) = result {
            controller.presentStoreError(error)
        }
    }

    private func selectFirstVisibleIfNeeded() {
        guard selectedID == nil || !visibleRows.contains(where: { $0.id == selectedID }) else { return }
        selectedID = visibleRows.first?.id
    }

    private func runStatusTitle(_ status: AppleShortcutRunStatus) -> String {
        switch status {
        case .running: plugin.localized("run.running", defaultValue: "正在运行")
        case .succeeded: plugin.localized("run.succeeded", defaultValue: "已完成")
        case .failed: plugin.localized("run.failed.status", defaultValue: "失败")
        case .cancelled: plugin.localized("run.cancelled", defaultValue: "已取消")
        }
    }

    private func runStatusImage(_ status: AppleShortcutRunStatus) -> String {
        switch status {
        case .running: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }
}

private struct AppleShortcutsFolderSyncReviewView: View {
    let plugin: AppleShortcutsPlugin
    let pending: PendingFolderSync
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var preview: AppleShortcutFolderSyncPreview {
        plugin.store.folderSyncPreview(members: pending.members)
    }

    private var disappearingCount: Int {
        plugin.store.disappearingShortcutCount(whenStoppingSync: pending.folder.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(pending.enable
                    ? plugin.localized("folder.sync.enable.title", defaultValue: "保持文件夹同步？")
                    : plugin.localized("folder.sync.disable.title", defaultValue: "停止同步文件夹？"))
                    .font(PluginSettingsTheme.Typography.pageTitle)
                Text(pending.folder.name)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }

            if pending.enable {
                Text(plugin.localizedFormat(
                    "folder.sync.enable.review",
                    defaultValue: "将新增 %lld 个操作。以后加入此文件夹的快捷指令也会自动启用。",
                    Int64(preview.additionIDs.count)
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)

                if preview.exceedsLimit {
                    Label(
                        plugin.localized(
                            "folder.sync.limit",
                            defaultValue: "启用后将超过 512 个快捷指令的上限。"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                }

                GroupBox(plugin.localized("folder.sync.members", defaultValue: "当前成员")) {
                    if pending.members.isEmpty {
                        Text(plugin.localized("folder.sync.members.empty", defaultValue: "此文件夹当前没有快捷指令。"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pending.members.sorted(by: memberOrder)) { member in
                                    HStack {
                                        Text(member.name)
                                            .font(PluginSettingsTheme.Typography.rowTitle)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(memberStatus(member.id))
                                            .font(PluginSettingsTheme.Typography.statusBadge)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                                    if member.id != pending.members.sorted(by: memberOrder).last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 120, maxHeight: 260)
                    }
                }
            } else {
                Text(plugin.localizedFormat(
                    "folder.sync.disable.review",
                    defaultValue: "停止同步后，%lld 个仅由此文件夹启用的操作将不再发布。",
                    Int64(disappearingCount)
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
            }

            HStack {
                Spacer()
                Button(plugin.localized("common.cancel", defaultValue: "取消"), action: onCancel)
                Button(
                    pending.enable
                        ? plugin.localized("folder.sync.enable.button", defaultValue: "保持同步")
                        : plugin.localized("folder.sync.disable.button", defaultValue: "停止同步"),
                    action: onConfirm
                )
                .buttonStyle(.borderedProminent)
                .disabled(pending.enable && preview.exceedsLimit)
                .accessibilityIdentifier("apple-shortcuts-folder-sync-confirm")
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 520)
    }

    private func memberStatus(_ id: UUID) -> String {
        if preview.excludedIDs.contains(id) {
            return plugin.localized("folder.sync.member.excluded", defaultValue: "保持停用")
        }
        if preview.additionIDs.contains(id) {
            return plugin.localized("folder.sync.member.add", defaultValue: "将启用")
        }
        return plugin.localized("folder.sync.member.enabled", defaultValue: "已启用")
    }

    private func memberOrder(_ lhs: AppleShortcutItem, _ rhs: AppleShortcutItem) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }
}
