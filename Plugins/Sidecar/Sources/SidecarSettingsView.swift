import SwiftUI
import MacToolsPluginKit

private enum SidecarSettingsColumnWidth {
    static let connection: CGFloat = 144
    static let shortcutAction: CGFloat = 112
    static let shortcut: CGFloat = 132
    static let clearShortcut: CGFloat = 20
}

struct SidecarSettingsView: View {
    @ObservedObject var store: SidecarPreferencesStore
    let liveDevices: [SidecarDevice]
    let localization: PluginLocalization
    let onRefresh: () -> Void
    let onUpdate: () -> Void
    let onBeginRecording: (String) -> Void
    let onEndRecording: () -> Void

    private static let disconnectAllID = "disconnect-all"

    private var displayedDevices: [SidecarDevicePreference] {
        let liveDevicesByID = Dictionary(uniqueKeysWithValues: liveDevices.map { ($0.id, $0) })
        return store.devices.filter {
            liveDevicesByID[$0.id] != nil || $0.hasCustomConfiguration
        }
        .sorted { lhs, rhs in
            let lhsRank = SidecarDeviceOrdering.rank(for: liveDevicesByID[lhs.id]?.connectionState)
            let rhsRank = SidecarDeviceOrdering.rank(for: liveDevicesByID[rhs.id]?.connectionState)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            savedDevicesSection
            disconnectAllSection
        }
    }

    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(
                    localization.string("settings.devices.title", defaultValue: "Sidecar 设备"),
                    systemImage: "display.2"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: onRefresh) {
                    Label(
                        localization.string("settings.refresh", defaultValue: "刷新"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(localization.string(
                "settings.devices.description",
                defaultValue: "设备离线时仍会保留它的设置和快捷键。"
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            Label(
                localization.string(
                    "panel.wired.warning",
                    defaultValue: "仅有线：不会回退到 Wi-Fi"
                ),
                systemImage: "cable.connector"
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            Text(localization.string(
                "settings.connectionMode.description",
                defaultValue: "Connection mode is used for the next menu or shortcut connection request."
            ))
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            if displayedDevices.isEmpty {
                ContentUnavailableView(
                    localization.string("settings.devices.empty.title", defaultValue: "未发现 Sidecar 设备"),
                    systemImage: "display",
                    description: Text(localization.string(
                        "settings.devices.empty.description",
                        defaultValue: "请让设备靠近并解锁，然后刷新。"
                    ))
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
                .pluginSettingsCardBackground(.host)
            } else {
                VStack(spacing: 0) {
                    SidecarDeviceSettingsColumnHeader(localization: localization)
                    PluginSettingsListDivider()

                    ForEach(displayedDevices) { preference in
                        SidecarDeviceSettingsRow(
                            preference: preference,
                            state: state(for: preference),
                            localization: localization,
                            onTransportChange: { transport in
                                store.updateTransport(transport, for: preference.id)
                                onUpdate()
                            },
                            onShortcutActionChange: { action in
                                store.updateShortcutAction(action, for: preference.id)
                                onUpdate()
                            },
                            onRecord: { binding in
                                guard !hasShortcutConflict(binding, excluding: preference.id) else {
                                    return .rejected(localization.string(
                                        "settings.shortcut.conflict",
                                        defaultValue: "此快捷键已用于其他 Sidecar 操作。"
                                    ))
                                }
                                store.updateShortcut(binding, for: preference.id)
                                onUpdate()
                                return .accepted
                            },
                            onClear: {
                                store.updateShortcut(nil, for: preference.id)
                                onUpdate()
                            },
                            onBeginRecording: {
                                onBeginRecording(preference.id)
                            },
                            onEndRecording: onEndRecording
                        )

                        if preference.id != displayedDevices.last?.id {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var disconnectAllSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.disconnectAll.title", defaultValue: "断开所有已连接设备"),
                systemImage: "rectangle.portrait.and.arrow.right"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(localization.string(
                    "settings.disconnectAll.description",
                    defaultValue: "只会断开 Sidecar 明确报告为已连接的显示器。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                PluginShortcutRecorder(
                    title: localization.string("settings.disconnectAll.title", defaultValue: "断开所有已连接设备"),
                    displayText: shortcutText(store.disconnectAllShortcut),
                    onRecord: { binding in
                        guard !hasShortcutConflict(binding, excluding: Self.disconnectAllID) else {
                            return .rejected(localization.string(
                                "settings.shortcut.conflict",
                                defaultValue: "此快捷键已用于其他 Sidecar 操作。"
                            ))
                        }
                        store.updateDisconnectAllShortcut(binding)
                        onUpdate()
                        return .accepted
                    },
                    onBeginRecording: { onBeginRecording(Self.disconnectAllID) },
                    onEndRecording: onEndRecording
                )

                if store.disconnectAllShortcut != nil {
                    Button(action: {
                        store.updateDisconnectAllShortcut(nil)
                        onUpdate()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .pluginSettingsRowIconStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.host)
        }
    }

    private func state(for preference: SidecarDevicePreference) -> SidecarDeviceSettingsState {
        guard let device = liveDevices.first(where: { $0.id == preference.id }) else {
            return .unavailable
        }
        switch device.connectionState {
        case .connected: return .connected
        case .disconnected: return .available
        case .unknown: return .unknown
        }
    }

    private func hasShortcutConflict(_ binding: ShortcutBinding, excluding id: String) -> Bool {
        if id != Self.disconnectAllID, store.disconnectAllShortcut == binding {
            return true
        }
        return store.devices.contains { preference in
            preference.id != id && preference.shortcut == binding
        }
    }

    private func shortcutText(_ binding: ShortcutBinding?) -> String {
        ShortcutFormatter.displayString(for: binding).replacingOccurrences(
            of: "None",
            with: localization.string("settings.shortcut.unset", defaultValue: "未设置")
        )
    }
}

private enum SidecarDeviceSettingsState {
    case connected
    case available
    case unknown
    case unavailable
}

private struct SidecarDeviceSettingsRow: View {
    let preference: SidecarDevicePreference
    let state: SidecarDeviceSettingsState
    let localization: PluginLocalization
    let onTransportChange: (SidecarConnectionTransport) -> Void
    let onShortcutActionChange: (SidecarShortcutAction) -> Void
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onClear: () -> Void
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: statusIcon)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(statusColor)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(preference.name)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)

                Text(statusText)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)

            Picker(String(), selection: Binding(
                get: { preference.transport },
                set: { transport in
                    onTransportChange(transport)
                }
            )) {
                Text(localization.string("settings.transport.automatic", defaultValue: "自动"))
                    .tag(SidecarConnectionTransport.automatic)
                Text(localization.string("settings.transport.wiredOnly", defaultValue: "仅有线"))
                    .tag(SidecarConnectionTransport.wiredOnly)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: SidecarSettingsColumnWidth.connection)
            .accessibilityLabel(localization.string("settings.column.connection", defaultValue: "连接方式"))
            .help(localization.string("settings.transport.help", defaultValue: "连接时使用的传输方式"))

            Picker(String(), selection: Binding(
                get: { preference.shortcutAction },
                set: { action in
                    onShortcutActionChange(action)
                }
            )) {
                Text(localization.string("settings.shortcutAction.toggle", defaultValue: "切换"))
                    .tag(SidecarShortcutAction.toggle)
                Text(localization.string("panel.action.connect", defaultValue: "连接"))
                    .tag(SidecarShortcutAction.connect)
                Text(localization.string("panel.action.disconnect", defaultValue: "断开连接"))
                    .tag(SidecarShortcutAction.disconnect)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: SidecarSettingsColumnWidth.shortcutAction)
            .accessibilityLabel(localization.string("settings.column.shortcutAction", defaultValue: "快捷键操作"))
            .help(localization.string("settings.shortcutAction.help", defaultValue: "此设备快捷键执行的操作"))

            PluginShortcutRecorder(
                title: preference.name,
                displayText: shortcutText,
                minWidth: SidecarSettingsColumnWidth.shortcut,
                onRecord: onRecord,
                onBeginRecording: onBeginRecording,
                onEndRecording: onEndRecording
            )
            .frame(width: SidecarSettingsColumnWidth.shortcut)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .pluginSettingsRowIconStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(preference.shortcut == nil ? 0 : 1)
            .allowsHitTesting(preference.shortcut != nil)
            .frame(width: SidecarSettingsColumnWidth.clearShortcut)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var shortcutText: String {
        ShortcutFormatter.displayString(for: preference.shortcut).replacingOccurrences(
            of: "None",
            with: localization.string("settings.shortcut.unset", defaultValue: "未设置")
        )
    }

    private var statusIcon: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .available: "circle"
        case .unknown: "questionmark.circle"
        case .unavailable: "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .available: .secondary
        case .unknown: .orange
        case .unavailable: .secondary
        }
    }

    private var statusText: String {
        switch state {
        case .connected:
            localization.string("settings.deviceStatus.connected", defaultValue: "已连接")
        case .available:
            localization.string("settings.deviceStatus.available", defaultValue: "可连接")
        case .unknown:
            localization.string("settings.deviceStatus.unknown", defaultValue: "连接状态未知")
        case .unavailable:
            localization.string("settings.deviceStatus.unavailable", defaultValue: "当前不可用")
        }
    }
}

private struct SidecarDeviceSettingsColumnHeader: View {
    let localization: PluginLocalization

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Color.clear.frame(width: PluginSettingsTheme.Size.rowIcon)
            Color.clear.frame(minWidth: 130, maxWidth: .infinity)

            Text(localization.string("settings.column.connection", defaultValue: "连接方式"))
                .frame(width: SidecarSettingsColumnWidth.connection, alignment: .leading)
            Text(localization.string("settings.column.shortcutAction", defaultValue: "快捷键操作"))
                .frame(width: SidecarSettingsColumnWidth.shortcutAction, alignment: .leading)
            Text(localization.string("settings.column.shortcut", defaultValue: "快捷键"))
                .frame(width: SidecarSettingsColumnWidth.shortcut, alignment: .center)
            Color.clear.frame(width: SidecarSettingsColumnWidth.clearShortcut)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
        .pluginSettingsListRowPadding(interactive: true)
    }
}
