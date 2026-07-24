import SwiftUI
import MacToolsPluginKit

struct KeepAwakeSettingsView: View {
    @Binding var keepDisplayOn: Bool
    @Binding var keepAwakeWithLidClosed: Bool
    let powerSourceState: KeepAwakePowerSourceState
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Label(
                    localization.string("settings.display.section", defaultValue: "屏幕"),
                    systemImage: "display"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string(
                            "settings.display.keepOn",
                            defaultValue: "保持屏幕常亮"
                        ))
                        .font(PluginSettingsTheme.Typography.rowTitle)

                        Text(localization.string(
                            "settings.display.keepOn.description",
                            defaultValue: "阻止休眠运行时，防止屏幕因空闲而关闭。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                    Toggle("", isOn: $keepDisplayOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                .pluginSettingsCardBackground(.plugin)
            }

            if powerSourceState.isPortableMac {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    Label(
                        localization.string("settings.lidClose.section", defaultValue: "MacBook"),
                        systemImage: "laptopcomputer"
                    )
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                            Text(localization.string(
                                "settings.lidClose.keepAwake",
                                defaultValue: "合盖保持唤醒"
                            ))
                            .font(PluginSettingsTheme.Typography.rowTitle)

                            Text(lidCloseDescription)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(lidCloseDescriptionColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                        Toggle("", isOn: $keepAwakeWithLidClosed)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                    .pluginSettingsCardBackground(.plugin)
                }
            }
        }
    }

    private var lidCloseDescription: String {
        if !powerSourceState.isPortableMac {
            return localization.string(
                "settings.lidClose.unavailable.notebook",
                defaultValue: "仅适用于 Mac 笔记本电脑。"
            )
        }

        if !powerSourceState.isOnExternalPower {
            if keepAwakeWithLidClosed {
                return localization.string(
                    "settings.lidClose.paused.power",
                    defaultValue: "• 正在等待电源，接通后自动启用。\n• 请保持 Mac 通风。\n• 切勿将其放入包中。"
                )
            }

            return localization.string(
                "settings.lidClose.unavailable.power",
                defaultValue: "仅在接通电源时生效。可随时启用。"
            )
        }

        return localization.string(
            "settings.lidClose.keepAwake.description",
            defaultValue: "• 使用电池时暂停，重新接通电源后恢复。\n• 请保持 Mac 通风。\n• 切勿将其放入包中。"
        )
    }

    private var lidCloseDescriptionColor: Color {
        keepAwakeWithLidClosed ? .orange : .secondary
    }
}
