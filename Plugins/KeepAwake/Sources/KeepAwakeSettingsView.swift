import Foundation
import SwiftUI
import MacToolsPluginKit

enum KeepAwakeSettingsSearchEntryID {
    static let keepDisplayOn = "keep-display-on"
    static let keepAwakeWithLidClosed = "keep-awake-with-lid-closed"
    static let keepScreenBasedToolsWorking = "keep-screen-based-tools-working"
}

struct KeepAwakeSettingsView: View {
    @Binding var keepDisplayOn: Bool
    @Binding var keepAwakeWithLidClosed: Bool
    @Binding var keepDesktopAvailableWithLidClosed: Bool
    let isVirtualDisplayAvailable: Bool
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
                            defaultValue: "防止 Mac 和屏幕因空闲而休眠。不会绕过锁定屏幕。"
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
                .pluginSettingsSearchAnchor(
                    pluginID: "keep-awake",
                    entryID: KeepAwakeSettingsSearchEntryID.keepDisplayOn
                )
            }

            if powerSourceState.isPortableMac {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                    Label(
                        localization.string("settings.lidClose.section", defaultValue: "MacBook"),
                        systemImage: "laptopcomputer"
                    )
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                                Text(localization.string(
                                    "settings.lidClose.keepAwake",
                                    defaultValue: "合盖保持唤醒"
                                ))
                                .font(PluginSettingsTheme.Typography.rowTitle)

                                if lidCloseWarningItems.isEmpty {
                                    Text(lidCloseDescription)
                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    KeepAwakeWarningList(
                                        items: lidCloseWarningItems,
                                        color: keepAwakeWithLidClosed ? .orange : .secondary
                                    )
                                }
                            }

                            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                            Toggle("", isOn: $keepAwakeWithLidClosed)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)

                        if keepAwakeWithLidClosed {
                            Divider()
                                .padding(.leading, PluginSettingsTheme.Spacing.rowHorizontal)

                            HStack(
                                alignment: .top,
                                spacing: PluginSettingsTheme.Spacing.rowContentControl
                            ) {
                                HStack(
                                    alignment: .top,
                                    spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                                ) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)

                                    VStack(
                                        alignment: .leading,
                                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                                    ) {
                                        Text(localization.string(
                                            "settings.virtualDisplay.keepDesktopAvailable",
                                            defaultValue: "让屏幕相关工具继续工作"
                                        ))
                                        .font(PluginSettingsTheme.Typography.rowTitle)

                                        Text(virtualDisplayDescription)
                                            .font(PluginSettingsTheme.Typography.rowDescription)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if isVirtualDisplayAvailable {
                                            KeepAwakeWarningList(
                                                items: virtualDisplayWarningItems,
                                                color: keepDesktopAvailableWithLidClosed
                                                    ? .orange
                                                    : .secondary
                                            )
                                        }
                                    }
                                }

                                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                                Toggle("", isOn: $keepDesktopAvailableWithLidClosed)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!isVirtualDisplayAvailable)
                            }
                            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                            .pluginSettingsSearchAnchor(
                                pluginID: "keep-awake",
                                entryID: KeepAwakeSettingsSearchEntryID.keepScreenBasedToolsWorking
                            )
                        }
                    }
                    .pluginSettingsCardBackground(.plugin)
                    .pluginSettingsSearchAnchor(
                        pluginID: "keep-awake",
                        entryID: KeepAwakeSettingsSearchEntryID.keepAwakeWithLidClosed
                    )
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

    private var lidCloseWarningItems: [String] {
        guard powerSourceState.isOnExternalPower || keepAwakeWithLidClosed else {
            return []
        }
        return warningItems(from: lidCloseDescription)
    }

    private var virtualDisplayDescription: String {
        guard isVirtualDisplayAvailable else {
            return localization.string(
                "settings.virtualDisplay.unavailable",
                defaultValue: "当前插件包不包含软件显示器组件。"
            )
        }

        return localization.string(
            "settings.virtualDisplay.description",
            defaultValue: "合盖后支持 Codex Computer Use、桌面自动化、屏幕共享和远程控制。"
        )
    }

    private var virtualDisplayWarningItems: [String] {
        [
            localization.string(
                "settings.virtualDisplay.warning.enableBeforeClosing",
                defaultValue: "请在合盖前启用。"
            ),
            localization.string(
                "settings.virtualDisplay.warning.lockScreen",
                defaultValue: "不会启用远程访问或绕过锁定屏幕。"
            ),
            localization.string(
                "settings.virtualDisplay.warning.systemUpdates",
                defaultValue: "实验性功能；macOS 更新后可能失效。"
            ),
        ]
    }

    private func warningItems(from value: String) -> [String] {
        value
            .split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^•\s*"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
    }
}

private struct KeepAwakeWarningList: View {
    let items: [String]
    let color: Color

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: PluginSettingsTheme.Spacing.rowTitleDescription
        ) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("•")
                        .accessibilityHidden(true)

                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}
