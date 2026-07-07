import SwiftUI
import MacToolsPluginKit

private enum ShortcutSettingsLayout {
    static let standardRecorderWidth: CGFloat = 126
    static let groupedRecorderWidth: CGFloat = 126
    static let groupedControlWidth: CGFloat = 192
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
        static let controlWidth = ShortcutSettingsLayout.groupedControlWidth
    }

    let group: ShortcutSettingsGroup
    let recordShortcut: (ShortcutSettingsItem, ShortcutBinding) -> String?
    let onBeginRecording: (ShortcutSettingsItem) -> Void
    let onClear: (ShortcutSettingsItem) -> Void
    let onReset: (ShortcutSettingsItem) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
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
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 10) {
                ForEach(group.items) { item in
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
                    .frame(width: Layout.controlWidth, alignment: .leading)
                }
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                controlLabel
                recorderButton
                actionButtons
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
                .fixedSize(horizontal: true, vertical: false)
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
