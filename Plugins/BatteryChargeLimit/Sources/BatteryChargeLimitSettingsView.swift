import SwiftUI
import MacToolsPluginKit

// MARK: - BatteryChargeLimitSettingsView
//
// Custom configuration view shown in the plugin's settings page. Surfaces:
//   1. A larger limit slider with explanation of the "no auto-resume" semantics
//   2. SMC capability diagnostic (which inhibit path the helper found)
//   3. A note about how this differs from macOS Optimized Battery Charging

struct BatteryChargeLimitSettingsView: View {
    @ObservedObject var store: BatteryChargeLimitStore
    var capabilities: BatterySMCCapabilities
    var snapshot: BatterySnapshot
    let localization: PluginLocalization

    @State private var sliderValue: Double

    init(
        store: BatteryChargeLimitStore,
        capabilities: BatterySMCCapabilities,
        snapshot: BatterySnapshot,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.store = store
        self.capabilities = capabilities
        self.snapshot = snapshot
        self.localization = localization
        _sliderValue = State(initialValue: Double(store.limitPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            limitSection
            behaviorSection
            compatibilitySection
        }
        .onChange(of: store.limitPercent) { _, newValue in
            sliderValue = Double(newValue)
        }
    }

    // MARK: - Sections

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: localization.string("settings.limit.title", defaultValue: "充电上限"), icon: "battery.75")

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                HStack(alignment: .firstTextBaseline) {
                    Text(localization.string("settings.limit.target", defaultValue: "目标电量"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Spacer()
                    Text("\(Int(sliderValue))%")
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                Slider(
                    value: $sliderValue,
                    in: Double(BatteryChargeLimits.minimumPercent)...Double(BatteryChargeLimits.maximumPercent),
                    step: Double(BatteryChargeLimits.percentStep),
                    onEditingChanged: { editing in
                        if !editing {
                            store.setLimitPercent(Int(sliderValue))
                        }
                    }
                )
                .controlSize(.small)

                Text(localization.string("settings.limit.description", defaultValue: "达到此电量后自动停止充电。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("settings.behavior.title", defaultValue: "充电行为"),
                icon: "bolt.badge.checkmark"
            )

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("settings.behavior.noAutoResume.title", defaultValue: "不自动恢复充电"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(
                    localization.string(
                        "settings.behavior.noAutoResume.description",
                        defaultValue: "电量低于上限时不会自动充电，需要在菜单栏点击「开始充电」才会继续。这与系统自带的「优化电池充电」不同——系统会持续微充电以贴近上限。"
                    )
                )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsListRowPadding()
            .pluginSettingsCardBackground(.host)
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(title: localization.string("settings.compatibility.title", defaultValue: "硬件兼容"), icon: "cpu")

            VStack(alignment: .leading, spacing: 0) {
                compatibilityRow(
                    title: localization.string("settings.compatibility.controlMethod", defaultValue: "充电控制方式"),
                    detail: capabilityDescription
                )

                if capabilities.canForceDischarge {
                    PluginSettingsListDivider()
                    compatibilityRow(
                        title: localization.string("settings.compatibility.forceDischarge", defaultValue: "强制放电"),
                        detail: localization.string("settings.compatibility.forceDischarge.supported", defaultValue: "支持（CH0I）")
                    )
                }

                if capabilities.isBCLMOnly {
                    PluginSettingsListDivider()
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Label(
                            localization.string("settings.compatibility.intelLimit.title", defaultValue: "Intel Mac 限制"),
                            systemImage: "exclamationmark.triangle"
                        )
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .foregroundStyle(.orange)
                        Text(
                            localization.string(
                                "settings.compatibility.intelLimit.description",
                                defaultValue: "当前 Mac 仅支持 BCLM，电量低于上限时仍可能被系统自动充至上限。「不自动恢复」语义在 Intel Mac 上无法保证。"
                            )
                        )
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func compatibilityRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Spacer()
            Text(detail)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
        .pluginSettingsListRowPadding()
    }

    private var capabilityDescription: String {
        if capabilities.hasCHIE {
            return "CHIE (macOS 15+)"
        }
        if capabilities.hasCH0BC {
            return "CH0B + CH0C (Apple Silicon)"
        }
        if capabilities.hasBCLM {
            return "BCLM (Intel)"
        }
        return localization.string("settings.compatibility.noSMCKey", defaultValue: "未检测到可用的 SMC 充电控制键")
    }
}
