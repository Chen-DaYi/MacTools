import SwiftUI
import MacToolsPluginKit

struct DisplayBrightnessSettingsView: View {
    @ObservedObject var preferences: DisplayBrightnessShortcutPreferences
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            shortcutSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.shortcutTarget.sectionTitle", defaultValue: "作用范围"),
                systemImage: "display.2"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string("settings.shortcutTarget.title", defaultValue: "快捷键目标"))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                        Text(preferences.targetMode.description(localization: localization))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("", selection: $preferences.targetMode) {
                        ForEach(DisplayBrightnessShortcutPreferences.TargetMode.allCases) { mode in
                            Text(mode.title(localization: localization)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.host)
        }
    }
}
