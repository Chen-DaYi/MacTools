import SwiftUI
import MacToolsPluginKit

enum KeepAwakeSettingsSearchEntryID {
    static let behavior = "behavior"
}

struct KeepAwakeSettingsView: View {
    @Binding var behavior: KeepAwakeBehavior
    let isVirtualDisplayAvailable: Bool
    let powerSourceState: KeepAwakePowerSourceState
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            VStack(
                alignment: .leading,
                spacing: PluginSettingsTheme.Spacing.sectionHeaderContent
            ) {
                Label(
                    localization.string(
                        "settings.mode.section",
                        defaultValue: "行为"
                    ),
                    systemImage: "slider.horizontal.3"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                VStack(
                    alignment: .leading,
                    spacing: PluginSettingsTheme.Spacing.rowContentControl
                ) {
                    behaviorSelector

                    Text(behaviorDescription)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)

                    if behavior == .keepScreenBasedToolsWorking {
                        KeepAwakeWarningList(items: screenToolsWarningItems, color: .orange)
                            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                .pluginSettingsCardBackground(.plugin)
                .pluginSettingsSearchAnchor(
                    pluginID: "keep-awake",
                    entryID: KeepAwakeSettingsSearchEntryID.behavior
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var behaviorSelector: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            ForEach(KeepAwakeBehavior.allCases, id: \.self) { option in
                let isSelected = behavior == option

                Button {
                    behavior = option
                } label: {
                    Text(behaviorTitle(option))
                        .font(PluginSettingsTheme.Typography.rowTitle.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: PluginSettingsTheme.Size.controlHeight + 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.control,
                        style: .continuous
                    )
                    .fill(
                        isSelected
                            ? Color.accentColor
                            : PluginSettingsTheme.Palette.recessedControlBackground
                    )
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PluginSettingsTheme.Spacing.controlCluster)
    }

    private func behaviorTitle(_ option: KeepAwakeBehavior) -> String {
        switch option {
        case .allowDisplayToTurnOff:
            localization.string(
                "settings.mode.keepMacAwake.title",
                defaultValue: "允许屏幕关闭"
            )
        case .keepDisplayOn:
            localization.string(
                "settings.display.keepOn",
                defaultValue: "保持常亮"
            )
        case .keepScreenBasedToolsWorking:
            localization.string(
                "settings.mode.screenTools.shortTitle",
                defaultValue: "屏幕工具"
            )
        }
    }

    private var behaviorDescription: String {
        switch behavior {
        case .allowDisplayToTurnOff:
            localization.string(
                "settings.mode.keepMacAwake.description",
                defaultValue: "保持 Mac 唤醒；屏幕关闭与锁定仍遵循 macOS 设置。"
            )
        case .keepDisplayOn:
            localization.string(
                "settings.display.keepOn.description",
                defaultValue: "保持屏幕常亮。自动锁定仍遵循 macOS 设置。"
            )
        case .keepScreenBasedToolsWorking:
            localization.string(
                "settings.mode.screenTools.description",
                defaultValue: "保持屏幕可用并防止自动锁定，适用于 Codex Computer Use、桌面自动化、屏幕共享和远程控制。"
            )
        }
    }

    private var screenToolsWarningItems: [String] {
        var items: [String] = []

        if powerSourceState.isPortableMac {
            items.append(
                localization.string(
                    "settings.automaticLock.warning.closedLidPower",
                    defaultValue: "合盖运行要求 MacBook 连接电源。"
                )
            )
            items.append(
                localization.string(
                    "settings.mode.screenTools.warning.ventilation",
                    defaultValue: "保持 Mac 通风，切勿将其放入包中。"
                )
            )
            if isVirtualDisplayAvailable {
                items.append(
                    localization.string(
                        "settings.mode.screenTools.warning.experimental",
                        defaultValue: "合盖软件显示器为实验性功能，macOS 更新后可能失效。"
                    )
                )
            } else {
                items.append(
                    localization.string(
                        "settings.mode.screenTools.warning.unavailable",
                        defaultValue: "当前插件包不包含合盖软件显示器组件。"
                    )
                )
            }
        }

        items.append(
            localization.string(
                "settings.mode.screenTools.warning.manualLock",
                defaultValue: "手动锁定仍然有效；不会解锁已锁定的会话。"
            )
        )
        return items
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
