import SwiftUI
import MacToolsPluginKit

struct WindowSwitcherSettingsView: View {
    @ObservedObject var store: WindowSwitcherStore
    let localization: PluginLocalization
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            statusSection
            modeSection
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("settings.status.sectionTitle", defaultValue: "状态"),
                icon: "power"
            )

            VStack(spacing: 0) {
                statusRow
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("settings.mode.sectionTitle", defaultValue: "切换模式"),
                icon: "rectangle.2.swap"
            )

            VStack(spacing: 0) {
                modeRow
                sortRow
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var statusRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "rectangle.2.swap")
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("settings.status.title", defaultValue: "启用窗口切换"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(statusDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var modeRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "keyboard")
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("settings.mode.title", defaultValue: "默认行为"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(modeDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Picker("", selection: modeBinding) {
                Text(localization.string("settings.mode.keyWindow", defaultValue: "按键直达"))
                    .tag(WindowSwitcherMode.keyWindow)
                Text(localization.string("settings.mode.directCycle", defaultValue: "连续切换"))
                    .tag(WindowSwitcherMode.directCycle)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var sortRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "arrow.up.arrow.down")
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("settings.sort.title", defaultValue: "排序"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(sortDescription)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Picker("", selection: sortModeBinding) {
                Text(localization.string("settings.sort.recentUse", defaultValue: "最近使用"))
                    .tag(WindowSwitcherSortMode.recentUse)
                Text(localization.string("settings.sort.fixed", defaultValue: "固定排序"))
                    .tag(WindowSwitcherSortMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var modeBinding: Binding<WindowSwitcherMode> {
        Binding(
            get: { store.configuration.mode },
            set: { mode in
                store.setMode(mode)
                onChange()
            }
        )
    }

    private var sortModeBinding: Binding<WindowSwitcherSortMode> {
        Binding(
            get: { store.configuration.sortMode },
            set: { sortMode in
                store.setSortMode(sortMode)
                onChange()
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.isEnabled },
            set: { isEnabled in
                store.setEnabled(isEnabled)
                onChange()
            }
        )
    }

    private var statusDescription: String {
        if store.configuration.isEnabled {
            return localization.string(
                "settings.status.enabled.description",
                defaultValue: "接管切换快捷键，显示并切换应用窗口。"
            )
        }

        return localization.string(
            "settings.status.disabled.description",
            defaultValue: "暂停快捷键监听，系统默认切换保持不变。"
        )
    }

    private var sortDescription: String {
        switch store.configuration.sortMode {
        case .recentUse:
            return localization.string(
                "settings.sort.recentUse.description",
                defaultValue: "按最近使用的应用排列，便于快速回到上一个窗口。"
            )
        case .fixed:
            return localization.string(
                "settings.sort.fixed.description",
                defaultValue: "按应用名称稳定排列，位置更容易记住。"
            )
        }
    }

    private var modeDescription: String {
        switch store.configuration.mode {
        case .keyWindow:
            return localization.string(
                "settings.mode.keyWindow.description",
                defaultValue: "显示固定窗口，按条目上方字母直达。"
            )
        case .directCycle:
            return localization.string(
                "settings.mode.directCycle.description",
                defaultValue: "按住快捷键循环选择，松开后切换窗口。"
            )
        }
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}
