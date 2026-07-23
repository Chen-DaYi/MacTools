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
                            defaultValue: "合盖时保持唤醒"
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
                        .disabled(!powerSourceState.canPreventLidCloseSleep)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                .pluginSettingsCardBackground(.plugin)
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
            return localization.string(
                "settings.lidClose.unavailable.power",
                defaultValue: "连接电源后可用。"
            )
        }

        return localization.string(
            "settings.lidClose.keepAwake.description",
            defaultValue: "阻止合盖休眠；请保持通风，勿放入包中。"
        )
    }

    private var lidCloseDescriptionColor: Color {
        powerSourceState.canPreventLidCloseSleep ? .orange : .secondary
    }
}
