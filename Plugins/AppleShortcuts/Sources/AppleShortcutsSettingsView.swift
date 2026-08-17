import AppKit
import MacToolsPluginKit
import SwiftUI

enum AppleShortcutsSource: Hashable {
    case all
    case folder(UUID)
}

struct AppleShortcutsDisplayRow: Identifiable {
    let item: AppleShortcutItem

    var id: UUID { item.id }
    var name: String { item.name }
}

enum AppleShortcutsSettingsFiltering {
    static func visibleRows(
        from rows: [AppleShortcutsDisplayRow],
        source: AppleShortcutsSource,
        searchText: String,
        folderIDsByShortcut: [UUID: Set<UUID>]
    ) -> [AppleShortcutsDisplayRow] {
        rows.filter { row in
            let matchesSource = switch source {
            case .all: true
            case let .folder(id): folderIDsByShortcut[row.id, default: []].contains(id)
            }
            let matchesSearch = searchText.isEmpty
                || row.name.localizedCaseInsensitiveContains(searchText)
                || row.id.uuidString.localizedCaseInsensitiveContains(searchText)
            return matchesSource && matchesSearch
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
        case .runImmediately: run()
        case .requireConfirmation: requestConfirmation()
        }
    }
}

struct AppleShortcutsSettingsView: View {
    let plugin: AppleShortcutsPlugin
    @ObservedObject private var controller: AppleShortcutsController
    @ObservedObject private var store: AppleShortcutsStore
    @ObservedObject private var executionStore: AppleShortcutsExecutionStore

    @State private var searchText = ""
    @State private var source: AppleShortcutsSource = .all
    @State private var selectedID: UUID?
    @State private var pendingRun: AppleShortcutsDisplayRow?

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
                    .frame(minWidth: 280, idealWidth: 360)
                detailPane
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
            .pluginSettingsCardBackground(.standard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(item: $pendingRun) { row in
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
        }
        .onAppear {
            controller.refreshIfNeeded()
            selectFirstVisibleIfNeeded()
        }
        .onChange(of: visibleRows.map(\.id)) { _, _ in
            selectFirstVisibleIfNeeded()
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

            Spacer()

            Text(plugin.localizedFormat(
                "settings.discovered.format",
                defaultValue: "%lld 个快捷指令",
                Int64(controller.snapshot.discovery.shortcuts.count)
            ))
            .font(PluginSettingsTheme.Typography.monospacedValue)
            .foregroundStyle(.secondary)

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
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if let loadError = store.loadError {
            statusBanner(
                loadError == "invalid-apple-shortcuts-settings"
                    ? plugin.localized("settings.invalid", defaultValue: "无法读取设置；原始数据已保留。")
                    : loadError,
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

            if !controller.snapshot.discovery.folders.isEmpty {
                Section(plugin.localized("source.folders", defaultValue: "文件夹")) {
                    ForEach(controller.snapshot.discovery.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .tag(AppleShortcutsSource.folder(folder.id))
                            .accessibilityIdentifier("apple-shortcuts-source-folder-\(folder.id.uuidString)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var shortcutList: some View {
        Group {
            if controller.snapshot.isRefreshing && controller.snapshot.lastSuccessfulRefresh == nil {
                ContentUnavailableView {
                    Label(plugin.localized("settings.loading", defaultValue: "正在读取快捷指令"), systemImage: "arrow.clockwise")
                } description: {
                    ProgressView()
                }
            } else if visibleRows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: searchText.isEmpty ? "square.stack.3d.up" : "magnifyingglass",
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
            AppleShortcutIcon(metadata: row.item.visualMetadata, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                let folderNames = folderNames(for: row)
                if !folderNames.isEmpty {
                    Text(AppleShortcutsSettingsFormatting.joinedFolderNames(folderNames))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if controller.isRunning(row.id) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedID,
           let row = allRows.first(where: { $0.id == selectedID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    HStack(alignment: .top, spacing: 14) {
                        AppleShortcutIcon(metadata: row.item.visualMetadata, size: 56)
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Text(row.name)
                                .font(PluginSettingsTheme.Typography.pageTitle)
                                .textSelection(.enabled)
                            Text(row.id.uuidString.lowercased())
                                .font(PluginSettingsTheme.Typography.monospacedValue)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            let folderNames = folderNames(for: row)
                            if !folderNames.isEmpty {
                                Text(plugin.localizedFormat(
                                    "source.folders.format",
                                    defaultValue: "文件夹：%@",
                                    AppleShortcutsSettingsFormatting.joinedFolderNames(folderNames)
                                ))
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Button {
                            requestRun(row)
                        } label: {
                            Label(plugin.localized("run.test", defaultValue: "运行"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(controller.isRunning(row.id))

                        Button {
                            controller.openInShortcuts(row.id)
                        } label: {
                            Label(plugin.localized("view.open", defaultValue: "在“快捷指令”中打开"), systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    policySection(for: row)

                    if let record = executionStore.record(for: row.id) {
                        executionResult(record)
                    }
                }
                .padding(PluginSettingsTheme.Spacing.section)
            }
        } else {
            ContentUnavailableView(
                plugin.localized("detail.empty", defaultValue: "选择一个快捷指令"),
                systemImage: "cursorarrow.click.2"
            )
        }
    }

    private func policySection(for row: AppleShortcutsDisplayRow) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(plugin.localized("detail.sources", defaultValue: "运行设置"), systemImage: "slider.horizontal.3")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { store.policy(for: row.id).requiresConfirmation },
                set: { present(store.setRequiresConfirmation($0, for: row.id)) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.localized("policy.confirm.title", defaultValue: "运行前确认"))
                    Text(plugin.localized("policy.confirm.description", defaultValue: "运行前显示确认提示。"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

        }
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsCardBackground(.recessed)
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
            if let output = capturedOutput ?? record.message {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .pluginSettingsCardBackground(.recessed)
            }
        }
    }

    private var allRows: [AppleShortcutsDisplayRow] {
        controller.snapshot.discovery.shortcuts.map(AppleShortcutsDisplayRow.init).sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }

    private var visibleRows: [AppleShortcutsDisplayRow] {
        AppleShortcutsSettingsFiltering.visibleRows(
            from: allRows,
            source: source,
            searchText: searchText,
            folderIDsByShortcut: Dictionary(uniqueKeysWithValues: allRows.map {
                ($0.id, $0.item.folderIDs)
            })
        )
    }

    private var emptyTitle: String {
        searchText.isEmpty
            ? plugin.localized("empty.library", defaultValue: "没有快捷指令")
            : plugin.localized("empty.search", defaultValue: "没有匹配项")
    }

    private var emptyDescription: String {
        searchText.isEmpty
            ? plugin.localized("empty.library.description", defaultValue: "请先在 Apple“快捷指令”中创建快捷指令，然后刷新。")
            : plugin.localized("empty.search.description", defaultValue: "请尝试其他搜索内容。")
    }

    private func folderNames(for row: AppleShortcutsDisplayRow) -> [String] {
        row.item.folderIDs.compactMap { plugin.folder(id: $0)?.name }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func requestRun(_ row: AppleShortcutsDisplayRow) {
        AppleShortcutsSettingsRunDisposition.route(
            policy: store.policy(for: row.id),
            requestConfirmation: { pendingRun = row },
            run: { run(row) }
        )
    }

    private func run(_ row: AppleShortcutsDisplayRow) {
        switch controller.startExecution(shortcutID: row.id, name: row.name) {
        case let .success(run):
            Task { @MainActor in
                _ = await controller.waitForExecution(run, shortcutID: row.id)
            }
        case let .failure(error):
            controller.presentExecutionStartError(error)
        }
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

    private func statusBanner(_ text: String, image: String, color: Color) -> some View {
        Label(text, systemImage: image)
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            .pluginSettingsCardBackground(.standard)
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

private struct AppleShortcutIcon: View {
    let metadata: AppleShortcutVisualMetadata?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(color)
            if let iconData = metadata?.iconTIFFData,
               let icon = NSImage(data: iconData) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var color: Color {
        guard let color = metadata?.color else { return .purple }
        return Color(
            red: color.red.clamped(to: 0 ... 1),
            green: color.green.clamped(to: 0 ... 1),
            blue: color.blue.clamped(to: 0 ... 1)
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
