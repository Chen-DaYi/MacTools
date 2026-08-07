import SwiftUI
import MacToolsPluginKit

private enum ShortcutSettingsLayout {
    static let standardRecorderWidth: CGFloat = 126
    static let groupedRecorderWidth: CGFloat = 126
    static let groupedControlMinWidth: CGFloat = 192
    static let groupedControlMaxWidth: CGFloat = 240
    static let groupedIconWidth: CGFloat = 22
    static let actionButtonSize: CGFloat = 22
    static let actionButtonsWidth: CGFloat = 50
}

struct ShortcutSettingsView: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"), systemImage: "command")
                        .font(PluginSettingsTheme.Typography.pageTitle)

                    Text(AppL10n.settings(
                        "shortcuts.description",
                        defaultValue: "为常用动作配置全局快捷键。编辑后立即生效，必要项不可删除。"
                    ))
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PluginSettingsTheme.Spacing.cardContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsCardBackground(.host)

                ShortcutSettingsRowsView(pluginHost: pluginHost, items: pluginHost.shortcutItems)
                .pluginSettingsCardBackground(.host)
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .background(SettingsStyle.contentBackground)
    }
}

private enum ActionShortcutFilter: String, CaseIterable, Identifiable {
    case all
    case assigned
    case unassigned
    case conflicted
    case unavailable

    var id: Self { self }

    var title: String {
        switch self {
        case .all: FeatureL10n.string("全部")
        case .assigned: FeatureL10n.string("已分配")
        case .unassigned: FeatureL10n.string("未分配")
        case .conflicted: FeatureL10n.string("冲突")
        case .unavailable: FeatureL10n.string("不可用")
        }
    }

    func includes(_ status: ActionShortcutCatalogStatus) -> Bool {
        switch (self, status) {
        case (.all, _), (.assigned, .assigned), (.unassigned, .unassigned),
             (.conflicted, .conflicted), (.unavailable, .unavailable):
            true
        default:
            false
        }
    }
}

private struct PendingActionShortcutReplacement: Identifiable {
    let reference: ActionReference
    let binding: ShortcutBinding
    let ownerDescription: String

    var id: ActionReference { reference }
}

struct ActionShortcutSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @State private var query = ""
    @State private var filter: ActionShortcutFilter = .all
    @State private var pendingReplacement: PendingActionShortcutReplacement?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                header
                controls

                if groupedItems.isEmpty {
                    ContentUnavailableView(
                        FeatureL10n.string("没有匹配的操作"),
                        systemImage: "command",
                        description: Text(FeatureL10n.string("调整搜索词或筛选条件后重试。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(groupedItems, id: \.providerID) { group in
                        actionGroup(group)
                    }
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .background(SettingsStyle.contentBackground)
        .alert(item: $pendingReplacement) { replacement in
            Alert(
                title: Text(FeatureL10n.string("替换快捷键？")),
                message: Text(FeatureL10n.format(
                    "此快捷键已分配给“%@”。替换后，原操作将不再使用它。",
                    replacement.ownerDescription
                )),
                primaryButton: .destructive(Text(FeatureL10n.string("替换"))) {
                    _ = pluginHost.setActionShortcutBinding(
                        replacement.binding,
                        to: replacement.reference,
                        replacingConflictingActionAssignments: true
                    )
                },
                secondaryButton: .cancel()
            )
        }
        .accessibilityIdentifier("mactools.actions-and-shortcuts")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(FeatureL10n.string("操作与快捷键"), systemImage: "command")
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(FeatureL10n.string("查找 MacTools 与插件操作，并在同一个冲突空间中管理全局快捷键。"))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.host)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            searchField

            HStack(spacing: 0) {
                filterPicker
                Spacer(minLength: 0)
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.host)
    }

    private var searchField: some View {
        TextField(FeatureL10n.string("搜索操作、插件或快捷键"), text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: .infinity)
            .accessibilityIdentifier("mactools.actions.search")
    }

    private var filterPicker: some View {
        Picker(FeatureL10n.string("筛选"), selection: $filter) {
            ForEach(ActionShortcutFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 420)
    }

    private var groupedItems: [ActionShortcutGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = pluginHost.actionShortcutCatalogItems.filter { item in
            guard filter.includes(item.status) else {
                return false
            }
            guard !normalizedQuery.isEmpty else {
                return true
            }
            return [item.title, item.ownerTitle, item.description, item.bindingText]
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }

        var order: [String] = []
        var groups: [String: [ActionShortcutCatalogItem]] = [:]
        for item in matching {
            let providerID = item.reference.key.providerID
            if groups[providerID] == nil {
                order.append(providerID)
            }
            groups[providerID, default: []].append(item)
        }
        return order.compactMap { providerID in
            guard let items = groups[providerID], let first = items.first else {
                return nil
            }
            return ActionShortcutGroup(
                providerID: providerID,
                title: first.ownerTitle,
                items: items
            )
        }
    }

    private func actionGroup(_ group: ActionShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(group.title, systemImage: group.providerID == "mactools" ? "hammer" : "puzzlepiece.extension")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                Spacer()

                if group.providerID != "mactools",
                   let reference = group.items.first?.reference,
                   pluginHost.canPresentActionOwner(for: reference) {
                    Button {
                        pluginHost.presentActionOwner(for: reference)
                    } label: {
                        Label(FeatureL10n.string("打开所属功能的设置"), systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    ActionShortcutCatalogRow(
                        pluginHost: pluginHost,
                        item: item,
                        displaysOwnerSettings: group.providerID == "mactools",
                        onRecord: { binding in record(binding, for: item) },
                        onClear: { pluginHost.clearActionShortcut(for: item.reference) }
                    )
                    if index < group.items.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private func record(
        _ binding: ShortcutBinding,
        for item: ActionShortcutCatalogItem
    ) -> PluginShortcutRecordingResult {
        switch pluginHost.setActionShortcutBinding(binding, to: item.reference) {
        case .success:
            return .accepted
        case let .failure(.conflict(ownerDescription)):
            pendingReplacement = PendingActionShortcutReplacement(
                reference: item.reference,
                binding: binding,
                ownerDescription: ownerDescription
            )
            return .pendingConfirmation
        case let .failure(error):
            return .rejected(error.localizedDescription)
        }
    }
}

private struct ActionShortcutGroup {
    let providerID: String
    let title: String
    let items: [ActionShortcutCatalogItem]
}

private struct ActionShortcutCatalogRow: View {
    private enum Layout {
        static let recorderWidth: CGFloat = 126
        static let actionButtonSize: CGFloat = 22
    }

    @ObservedObject var pluginHost: PluginHost
    let item: ActionShortcutCatalogItem
    let displaysOwnerSettings: Bool
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(
                    alignment: .leading,
                    spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                ) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .lineLimit(1)
                        statusBadge
                    }

                    Text(supportingText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PluginShortcutRecorder(
                    title: item.title,
                    displayText: item.bindingText,
                    minWidth: Layout.recorderWidth,
                    onRecord: onRecord
                )
                .frame(width: Layout.recorderWidth)
                .disabled(!item.canAssign)

                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Layout.actionButtonSize, height: Layout.actionButtonSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(FeatureL10n.string("清除快捷键"))
                .opacity(item.bindingText.isEmpty ? 0 : 1)
                .disabled(item.bindingText.isEmpty)
            }

            ActionRunLinkControl(
                pluginHost: pluginHost,
                reference: item.reference,
                displaysUnavailableReason: false
            )
            .padding(.leading, 24 + PluginSettingsTheme.Spacing.rowContentControl)

            if displaysOwnerSettings,
               pluginHost.canPresentActionOwner(for: item.reference) {
                Button {
                    pluginHost.presentActionOwner(for: item.reference)
                } label: {
                    Label(FeatureL10n.string("打开所属功能的设置"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 24 + PluginSettingsTheme.Spacing.rowContentControl)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(statusTitle)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusTitle: String {
        switch item.status {
        case .assigned: FeatureL10n.string("已分配")
        case .unassigned: FeatureL10n.string("未分配")
        case .conflicted: FeatureL10n.string("冲突")
        case .unavailable: FeatureL10n.string("不可用")
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .assigned: .green
        case .unassigned: .secondary
        case .conflicted: .orange
        case .unavailable: .red
        }
    }

    private var supportingText: String {
        switch item.status {
        case .assigned, .unassigned:
            [item.description, item.permissionSummary]
                .compactMap { $0 }
                .joined(separator: " · ")
        case let .conflicted(owner):
            FeatureL10n.format("与“%@”冲突。", owner)
        case let .unavailable(reason):
            reason ?? FeatureL10n.string("此操作当前不可用。")
        }
    }
}

struct ShortcutSettingsRowsView: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ShortcutSettingsStandardRow(
                    item: item,
                    recordShortcut: { binding in
                        configure(item, binding: binding)
                    },
                    onConfigure: {
                        pluginHost.clearShortcutError(for: item.id)
                    },
                    onClear: {
                        clear(item)
                    },
                    onReset: {
                        reset(item)
                    }
                )
                .pluginSettingsSearchAnchor(
                    pluginID: item.pluginID,
                    entryID: item.id
                )

                if index < items.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    private func configure(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        pluginHost.clearShortcutError(for: item.id)
        return pluginHost.setShortcutBindingAndReturnError(binding, for: item.id)
    }

    private func clear(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.clearShortcut(for: item.id)
    }

    private func reset(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.resetShortcut(for: item.id)
    }
}

struct GroupedShortcutSettingsRowsView: View {
    @ObservedObject var pluginHost: PluginHost
    let groups: [ShortcutSettingsGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                GroupedShortcutSettingsRow(
                    group: group,
                    recordShortcut: configure,
                    onBeginRecording: { item in
                        pluginHost.clearShortcutError(for: item.id)
                    },
                    onClear: clear,
                    onReset: reset
                )
                .pluginSettingsSearchAnchor(
                    pluginID: group.items.first?.pluginID ?? "",
                    entryID: group.id
                )

                if index < groups.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    private func configure(_ item: ShortcutSettingsItem, binding: ShortcutBinding) -> String? {
        pluginHost.clearShortcutError(for: item.id)
        return pluginHost.setShortcutBindingAndReturnError(binding, for: item.id)
    }

    private func clear(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.clearShortcut(for: item.id)
    }

    private func reset(_ item: ShortcutSettingsItem) {
        pluginHost.clearShortcutError(for: item.id)
        pluginHost.resetShortcut(for: item.id)
    }
}

struct ShortcutSettingsGroup: Identifiable {
    let id: String
    let title: String
    let description: String?
    let items: [ShortcutSettingsItem]
}

private struct ShortcutSettingsStandardRow: View {
    let item: ShortcutSettingsItem
    let recordShortcut: (ShortcutBinding) -> String?
    let onConfigure: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    private var supportingText: String {
        item.errorMessage ?? item.description
    }

    private var supportingColor: Color {
        item.errorMessage == nil ? .secondary : .red
    }

    private var rowHelpText: String {
        [item.title, supportingText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(item.title)

                    if item.isRequired {
                        ShortcutStatusBadge(text: AppL10n.settings("shortcuts.required", defaultValue: "必填"))
                    }
                }

                if !supportingText.isEmpty {
                    Text(supportingText)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(supportingColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(supportingText)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(rowHelpText)

            HStack(alignment: .center, spacing: 10) {
                ShortcutBindingControl(
                    item: item,
                    onRecord: { binding in
                        PluginShortcutRecordingResult.from(
                            errorMessage: recordShortcut(binding)
                        )
                    },
                    onBeginRecording: onConfigure,
                    onConfigure: onConfigure,
                    onReset: onReset,
                    onClear: onClear
                )
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupedShortcutSettingsRow: View {
    private enum Layout {
        static let spacing = PluginSettingsTheme.Spacing.rowContentControl
        static let summaryMinWidth: CGFloat = 220
        static let controlMinWidth = ShortcutSettingsLayout.groupedControlMinWidth
        static let controlMaxWidth = ShortcutSettingsLayout.groupedControlMaxWidth
    }

    let group: ShortcutSettingsGroup
    let recordShortcut: (ShortcutSettingsItem, ShortcutBinding) -> String?
    let onBeginRecording: (ShortcutSettingsItem) -> Void
    let onClear: (ShortcutSettingsItem) -> Void
    let onReset: (ShortcutSettingsItem) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                groupSummary
                fixedWidthControls
            }

            VStack(alignment: .leading, spacing: Layout.spacing) {
                groupSummary
                adaptiveControls
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupSummary: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Text(group.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.title)

            if !supportingText.isEmpty {
                Text(supportingText)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(supportingColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(supportingText)
            }
        }
        .frame(
            minWidth: Layout.summaryMinWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var fixedWidthControls: some View {
        HStack(alignment: .center, spacing: Layout.spacing) {
            ForEach(group.items) { item in
                shortcutControl(for: item)
                    .frame(width: Layout.controlMaxWidth, alignment: .leading)
            }
        }
    }

    private var adaptiveControls: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: Layout.controlMinWidth,
                        maximum: Layout.controlMaxWidth
                    ),
                    spacing: Layout.spacing,
                    alignment: .leading
                )
            ],
            alignment: .leading,
            spacing: Layout.spacing
        ) {
            ForEach(group.items) { item in
                shortcutControl(for: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutControl(for item: ShortcutSettingsItem) -> some View {
        ShortcutBindingControl(
            item: item,
            onRecord: { binding in
                PluginShortcutRecordingResult.from(
                    errorMessage: recordShortcut(item, binding)
                )
            },
            onBeginRecording: { onBeginRecording(item) },
            onConfigure: { onBeginRecording(item) },
            onReset: { onReset(item) },
            onClear: { onClear(item) },
            title: item.settingsControlTitle ?? item.title,
            systemImage: item.settingsControlSystemImage,
            layout: .stacked
        )
    }

    private var supportingText: String {
        let messages = group.items.compactMap(\.errorMessage)
        if !messages.isEmpty {
            return messages.joined(separator: "；")
        }

        return group.description ?? ""
    }

    private var supportingColor: Color {
        group.items.contains(where: { $0.errorMessage != nil }) ? .red : .secondary
    }
}

private struct ShortcutBindingControl: View {
    enum LayoutStyle: Equatable {
        case horizontal
        case stacked
    }

    let item: ShortcutSettingsItem
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: () -> Void
    let onConfigure: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void
    var title: String? = nil
    var systemImage: String? = nil
    var layout: LayoutStyle = .horizontal

    var body: some View {
        switch layout {
        case .horizontal:
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                recorderButton
                actionButtons
            }
        case .stacked:
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                controlLabel

                HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    recorderButton
                    actionButtons
                }
            }
        }
    }

    @ViewBuilder
    private var controlLabel: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: ShortcutSettingsLayout.groupedIconWidth, alignment: .center)
                .accessibilityLabel(Text(title ?? item.title))
                .help(title ?? item.title)
        } else if let title {
            Text(title)
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(title)
        }
    }

    private var recorderWidth: CGFloat {
        switch layout {
        case .horizontal:
            return ShortcutSettingsLayout.standardRecorderWidth
        case .stacked:
            return ShortcutSettingsLayout.groupedRecorderWidth
        }
    }

    private var recorderButton: some View {
        PluginShortcutRecorder(
            title: title ?? item.title,
            displayText: item.bindingText,
            minWidth: recorderWidth,
            onRecord: onRecord,
            onBeginRecording: onBeginRecording
        )
        .frame(width: recorderWidth)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if shouldShowReset || item.canClear {
            HStack(spacing: 6) {
                if shouldShowReset {
                    ShortcutInlineActionButton(
                        systemName: "arrow.counterclockwise",
                        helpText: AppL10n.settings("shortcuts.resetHelp", defaultValue: "重置为默认快捷键"),
                        action: onReset
                    )
                }

                if item.canClear {
                    ShortcutInlineActionButton(
                        systemName: "xmark.circle.fill",
                        helpText: AppL10n.settings("shortcuts.clearHelp", defaultValue: "清除快捷键"),
                        action: onClear
                    )
                }
            }
            .frame(width: actionButtonsWidth, alignment: .leading)
        }
    }

    private var shouldShowReset: Bool {
        guard layout == .horizontal || item.isRequired else {
            return false
        }

        return !item.usesDefaultValue
    }

    private var actionButtonsWidth: CGFloat {
        shouldShowReset && item.canClear
            ? ShortcutSettingsLayout.actionButtonsWidth
            : ShortcutSettingsLayout.actionButtonSize
    }
}

private struct ShortcutStatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(SettingsStyle.activeControlBackground)
            )
    }
}

private struct ShortcutInlineActionButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(PluginSettingsTheme.Typography.rowIcon)
                .symbolRenderingMode(.monochrome)
                .frame(
                    width: ShortcutSettingsLayout.actionButtonSize,
                    height: ShortcutSettingsLayout.actionButtonSize
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help(helpText)
    }
}
