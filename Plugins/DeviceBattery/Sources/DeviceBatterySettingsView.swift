import SwiftUI
import MacToolsPluginKit

struct DeviceBatterySettingsView: View {
    @ObservedObject var store: DeviceBatteryStore
    let localization: PluginLocalization
    let onChange: () -> Void
    let onNotificationSettingsChange: () -> Void
    @State private var thresholdText: String

    init(
        store: DeviceBatteryStore,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onChange: @escaping () -> Void,
        onNotificationSettingsChange: @escaping () -> Void = {}
    ) {
        self.store = store
        self.localization = localization
        self.onChange = onChange
        self.onNotificationSettingsChange = onNotificationSettingsChange
        _thresholdText = State(initialValue: "\(store.lowBatteryNotificationThreshold)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            layoutSection
            sourceSection
            notificationSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: store.lowBatteryNotificationThreshold) { _, newValue in
            thresholdText = "\(newValue)"
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                systemName: "rectangle.grid.2x2",
                title: localization.string("settings.layout.title", defaultValue: "组件布局")
            )

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    ForEach(DeviceBatteryLayoutMode.allCases, id: \.self) { mode in
                        DeviceBatteryLayoutModeButton(
                            mode: mode,
                            isSelected: store.layoutMode == mode,
                            iconSystemName: iconName(for: mode),
                            localization: localization,
                            action: {
                                store.setLayoutMode(mode)
                                onChange()
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                systemName: "bolt.horizontal.circle",
                title: localization.string("settings.sources.title", defaultValue: "显示内容")
            )

            VStack(spacing: 0) {
                sourceToggle(
                    title: localization.string("settings.source.internal.title", defaultValue: "Mac 内置电池"),
                    description: localization.string(
                        "settings.source.internal.description",
                        defaultValue: "显示本机电量、充电状态和剩余时间。"
                    ),
                    isOn: store.showInternalBattery,
                    isFirst: true,
                    action: store.setShowInternalBattery
                )
                sourceToggle(
                    title: localization.string("settings.source.bluetooth.title", defaultValue: "蓝牙与 Apple 外设"),
                    description: localization.string(
                        "settings.source.bluetooth.description",
                        defaultValue: "读取系统可见的蓝牙设备、AirPods 分体电量和 Magic 外设。"
                    ),
                    isOn: store.showBluetoothDevices,
                    action: store.setShowBluetoothDevices
                )
                sourceToggle(
                    title: localization.string("settings.source.rapoo.title", defaultValue: "厂商 HID 鼠标"),
                    description: localization.string(
                        "settings.source.rapoo.description",
                        defaultValue: "读取已适配鼠标的电量、充电状态、设备型号和名称。"
                    ),
                    isOn: store.showRapooDevices,
                    isLast: true,
                    action: store.setShowRapooDevices
                )
            }
            .pluginSettingsCardBackground(.plugin)
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                systemName: "bell.badge",
                title: localization.string("settings.notification.title", defaultValue: "低电量通知")
            )

            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text(localization.string("settings.notification.lowBattery.title", defaultValue: "发送低电量通知"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                        Text(localization.string(
                            "settings.notification.lowBattery.description",
                            defaultValue: "设备电量低于阈值时发送系统通知。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: Binding(
                        get: { store.lowBatteryNotificationEnabled },
                        set: { newValue in
                            store.setLowBatteryNotificationEnabled(newValue)
                            onNotificationSettingsChange()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

                if store.lowBatteryNotificationEnabled {
                    Divider()
                        .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)

                    thresholdRow
                }
            }
            .pluginSettingsCardBackground(.plugin)
        }
    }

    private var thresholdRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("settings.notification.threshold.title", defaultValue: "通知阈值"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(localization.string(
                    "settings.notification.threshold.description",
                    defaultValue: "低于此百分比时提醒。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 12)

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                TextField(
                    "",
                    text: Binding(
                        get: { thresholdText },
                        set: { newValue in
                            thresholdText = newValue.filter(\.isNumber)
                            guard let threshold = Int(thresholdText) else {
                                return
                            }

                            store.setLowBatteryNotificationThreshold(threshold)
                            onNotificationSettingsChange()
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .onSubmit(commitThresholdText)

                Text("%")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)

                Stepper("", value: Binding(
                    get: { store.lowBatteryNotificationThreshold },
                    set: { newValue in
                        store.setLowBatteryNotificationThreshold(newValue)
                        onNotificationSettingsChange()
                    }
                ), in: DeviceBatteryLowBatteryThresholds.minimum...DeviceBatteryLowBatteryThresholds.maximum)
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
    }

    private func sourceToggle(
        title: String,
        description: String,
        isOn: Bool,
        isFirst: Bool = false,
        isLast: Bool = false,
        action: @escaping (Bool) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider()
                    .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(title)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Text(description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: {
                        action($0)
                        onChange()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
        }
    }

    private func sectionHeader(systemName: String, title: String) -> some View {
        Label {
            Text(title)
                .font(PluginSettingsTheme.Typography.sectionTitle)
        } icon: {
            Image(systemName: systemName)
        }
        .foregroundStyle(.secondary)
    }

    private func commitThresholdText() {
        let threshold = Int(thresholdText) ?? store.lowBatteryNotificationThreshold
        store.setLowBatteryNotificationThreshold(threshold)
        thresholdText = "\(store.lowBatteryNotificationThreshold)"
        onNotificationSettingsChange()
    }

    private func iconName(for mode: DeviceBatteryLayoutMode) -> String {
        switch mode {
        case .grid:
            return "list.bullet.rectangle"
        case .list:
            return "gauge.with.dots.needle.67percent"
        }
    }
}

private struct DeviceBatteryLayoutModeButton: View {
    let mode: DeviceBatteryLayoutMode
    let isSelected: Bool
    let iconSystemName: String
    let localization: PluginLocalization
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: iconSystemName)
                    .pluginSettingsRowIconStyle(isSelected ? Color.accentColor : Color.primary)

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(mode.title(localization: localization))
                        .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                        .lineLimit(1)

                    Text(mode.subtitle(localization: localization))
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(isSelected ? Color.accentColor.opacity(0.78) : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: PluginSettingsTheme.Size.controlHeight * 2)
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
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
    }
}
