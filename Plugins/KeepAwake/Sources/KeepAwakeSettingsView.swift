import SwiftUI
import MacToolsPluginKit

struct KeepAwakeSettingsView: View {
    @Binding var keepDisplayOn: Bool
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
        }
    }
}
