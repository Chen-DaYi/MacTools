import SwiftUI
import MacToolsPluginKit

struct FixDamagedAppSettingsView: View {
    let onToggle: (Bool) -> Void
    let localization: PluginLocalization

    @State private var isEnabled: Bool

    init(
        isDragDetectionEnabled: Bool,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onToggle: @escaping (Bool) -> Void
    ) {
        self.onToggle = onToggle
        self.localization = localization
        self._isEnabled = State(initialValue: isDragDetectionEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(localization.string("settings.section.behavior", defaultValue: "行为"), systemImage: "hand.rays")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "hand.draw")
                    .pluginSettingsRowIconStyle(.secondary)

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(localization.string("settings.dragDetection.title", defaultValue: "拖动检测"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(localization.string(
                        "settings.dragDetection.description",
                        defaultValue: "拖入 .app 文件后松手，自动弹出修复窗口并开始修复。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: isEnabled) { _, newValue in
                        onToggle(newValue)
                    }
            }
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsCardBackground(.host)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
