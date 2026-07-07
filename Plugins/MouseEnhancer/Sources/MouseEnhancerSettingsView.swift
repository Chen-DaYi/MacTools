import SwiftUI
import MacToolsPluginKit

struct MouseEnhancerSettingsView: View {
    @ObservedObject var store: MouseEnhancerStore
    let localization: PluginLocalization
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            mouseSection
            trackpadSection
        }
    }

    private var mouseSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: localization.string("settings.mouse.sectionTitle", defaultValue: "鼠标"), icon: "computermouse")

            VStack(spacing: 0) {
                toggleRow(
                    title: localization.string("settings.mouse.vertical.title", defaultValue: "垂直反转"),
                    description: localization.string("settings.mouse.vertical.description", defaultValue: "反转鼠标上下滚动方向。"),
                    icon: "arrow.up.and.down",
                    isOn: mouseVerticalBinding
                )

                PluginSettingsListDivider()

                toggleRow(
                    title: localization.string("settings.mouse.horizontal.title", defaultValue: "水平反转"),
                    description: localization.string("settings.mouse.horizontal.description", defaultValue: "反转鼠标左右滚动方向。"),
                    icon: "arrow.left.and.right",
                    isOn: mouseHorizontalBinding
                )
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: localization.string("settings.trackpad.sectionTitle", defaultValue: "触控板"), icon: "hand.draw")

            VStack(spacing: 0) {
                toggleRow(
                    title: localization.string("settings.trackpad.vertical.title", defaultValue: "垂直反转"),
                    description: localization.string("settings.trackpad.vertical.description", defaultValue: "反转触控板和 Magic Mouse 上下滚动方向。"),
                    icon: "arrow.up.and.down",
                    isOn: trackpadVerticalBinding
                )

                PluginSettingsListDivider()

                toggleRow(
                    title: localization.string("settings.trackpad.horizontal.title", defaultValue: "水平反转"),
                    description: localization.string("settings.trackpad.horizontal.description", defaultValue: "反转触控板和 Magic Mouse 左右滚动方向。"),
                    icon: "arrow.left.and.right",
                    isOn: trackpadHorizontalBinding
                )

                PluginSettingsListDivider()

                toggleRow(
                    title: localization.string("settings.middleClick.title", defaultValue: "模拟鼠标中键"),
                    description: localization.string("settings.middleClick.description", defaultValue: "触控板轻点模拟鼠标中键点击。"),
                    icon: "hand.tap",
                    isOn: middleClickEnabledBinding
                )

                if store.configuration.middleClickEnabled {
                    PluginSettingsListDivider()
                    fingerCountRow
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var fingerCountRow: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Image(systemName: "hand.raised")
                        .pluginSettingsRowIconStyle()

                    Text(localization.string("settings.middleClick.fingerCount.title", defaultValue: "手指数量"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                }

                Text(localization.string(
                    "settings.middleClick.fingerCount.description",
                    defaultValue: "用指定数量的手指在触控板上轻点，将模拟鼠标中键点击。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                ForEach([3, 4, 5], id: \.self) { count in
                    FingerCountButton(
                        count: count,
                        isSelected: store.configuration.middleClickFingerCount == count,
                        localization: localization,
                        action: {
                            store.setMiddleClickFingerCount(count)
                            onChange()
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsListRowPadding()
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func toggleRow(
        title: String,
        description: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        MouseEnhancerToggleRow(
            title: title,
            description: description,
            icon: icon,
            isOn: isOn
        )
    }

    private var mouseVerticalBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.reverseMouseVertical },
            set: { value in
                store.setReverseMouseVertical(value)
                onChange()
            }
        )
    }

    private var mouseHorizontalBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.reverseMouseHorizontal },
            set: { value in
                store.setReverseMouseHorizontal(value)
                onChange()
            }
        )
    }

    private var trackpadVerticalBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.reverseTrackpadVertical },
            set: { value in
                store.setReverseTrackpadVertical(value)
                onChange()
            }
        )
    }

    private var trackpadHorizontalBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.reverseTrackpadHorizontal },
            set: { value in
                store.setReverseTrackpadHorizontal(value)
                onChange()
            }
        )
    }

    private var middleClickEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.configuration.middleClickEnabled },
            set: { value in
                store.setMiddleClickEnabled(value)
                onChange()
            }
        )
    }
}

private struct MouseEnhancerToggleRow: View {
    let title: String
    let description: String
    let icon: String
    @Binding var isOn: Bool

    @State private var toggleID = UUID()

    init(
        title: String,
        description: String,
        icon: String,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: icon)
                .pluginSettingsRowIconStyle()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .id(toggleID)
        }
        .pluginSettingsListRowPadding()
        .onAppear {
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
    }
}

private struct FingerCountButton: View {
    let count: Int
    let isSelected: Bool
    let localization: PluginLocalization
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: "hand.raised")
                    .pluginSettingsRowIconStyle(isSelected ? Color.accentColor : Color.primary)

                Text(localization.format("settings.middleClick.fingerCount.optionFormat", defaultValue: "%d指", count))
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: PluginSettingsTheme.Size.controlHeight * 2)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                .fill(
                    isSelected
                        ? PluginSettingsTheme.Palette.activeControlBackground
                        : PluginSettingsTheme.Palette.recessedControlBackground
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor.opacity(0.35)
                        : Color.clear,
                    lineWidth: PluginSettingsTheme.Stroke.standard
                )
        )
    }
}

#Preview {
    MouseEnhancerSettingsView(
        store: MouseEnhancerStore(storage: UserDefaultsPluginStorage(pluginID: "mouse-enhancer-preview")),
        localization: PluginLocalization(bundle: .main),
        onChange: {}
    )
    .frame(width: 440)
    .padding(24)
}
