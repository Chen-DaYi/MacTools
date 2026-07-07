import SwiftUI
import MacToolsPluginKit

// MARK: - FanControlPresetManagerView

struct FanControlPresetManagerView: View {
    @ObservedObject var presetStore: FanControlPresetStore
    /// Live snapshot for showing actual hardware max RPM in sliders.
    var fanSnapshot: FanSnapshot
    var localization: PluginLocalization = PluginLocalization(bundle: .main)

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            builtInSection
            customSection
        }
    }

    // MARK: - Built-in Section

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                title: localization.string("settings.builtIn.title", defaultValue: "内置预设"),
                icon: "lock"
            )

            VStack(spacing: 0) {
                ForEach(FanControlPresetStore.builtInPresets) { preset in
                    BuiltInPresetRow(
                        preset: preset,
                        fanSnapshot: fanSnapshot,
                        localization: localization
                    )
                    if preset.id != FanControlPresetStore.builtInPresets.last?.id {
                        PluginSettingsListDivider()
                    }
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    // MARK: - Custom Section

    private var customSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(
                    title: localization.string("settings.custom.title", defaultValue: "自定义预设"),
                    icon: "slider.horizontal.3"
                )
                Spacer()
                Button(action: addPreset) {
                    Label(localization.string("settings.custom.add", defaultValue: "添加"), systemImage: "plus")
                        .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if presetStore.customPresets.isEmpty {
                emptyCustomPresetsView
            } else {
                VStack(spacing: 0) {
                    ForEach(presetStore.customPresets) { preset in
                        CustomPresetRow(
                            preset: preset,
                            fanSnapshot: fanSnapshot,
                            localization: localization,
                            onRename: { presetStore.renameCustomPreset(id: preset.id, newName: $0) },
                            onRPMChange: { presetStore.updateCustomPresetRPM(id: preset.id, rpm: $0) },
                            onDelete: { presetStore.deleteCustomPreset(id: preset.id) }
                        )
                        if preset.id != presetStore.customPresets.last?.id {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var emptyCustomPresetsView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string("settings.custom.empty", defaultValue: "点击「添加」创建自定义转速预设"))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
        .pluginSettingsCardBackground(.host)
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func addPreset() {
        _ = presetStore.addCustomPreset()
    }
}

// MARK: - BuiltInPresetRow

private struct BuiltInPresetRow: View {
    let preset: FanPreset
    let fanSnapshot: FanSnapshot
    let localization: PluginLocalization

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(preset.displayName(localization: localization))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(localization.string("settings.builtIn.badge", defaultValue: "内置"))
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
        }
        .pluginSettingsListRowPadding()
    }

    private var subtitle: String {
        switch preset.strategy {
        case .auto:
            return localization.string("settings.builtIn.auto.subtitle", defaultValue: "由 macOS 自动管理")
        case .fullSpeed:
            let max = fanSnapshot.globalMaxSpeed
            return max > 0
                ? localization.format("preset.fullSpeed.subtitleWithRPM", defaultValue: "最高 %d RPM", max)
                : localization.string("preset.fullSpeed.subtitle", defaultValue: "最高转速")
        case .fixed(let rpm):
            return "\(rpm) RPM"
        }
    }
}

// MARK: - CustomPresetRow

private struct CustomPresetRow: View {
    let preset: FanPreset
    let fanSnapshot: FanSnapshot
    let localization: PluginLocalization
    let onRename: (String) -> Void
    let onRPMChange: (Int) -> Void
    let onDelete: () -> Void

    @State private var nameText: String
    @State private var sliderValue: Double
    @FocusState private var isNameFocused: Bool
    @State private var isNameHovered = false

    init(
        preset: FanPreset,
        fanSnapshot: FanSnapshot,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onRename: @escaping (String) -> Void,
        onRPMChange: @escaping (Int) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.preset = preset
        self.fanSnapshot = fanSnapshot
        self.localization = localization
        self.onRename = onRename
        self.onRPMChange = onRPMChange
        self.onDelete = onDelete
        let rpm = { if case .fixed(let r) = preset.strategy { return r }; return FanRPMLimits.defaultCustomRPM }()
        _nameText = State(initialValue: preset.name)
        _sliderValue = State(initialValue: Double(rpm))
    }

    private var currentRPM: Int {
        if case .fixed(let r) = preset.strategy { return r }
        return FanRPMLimits.defaultCustomRPM
    }

    private func resignFocus() {
        isNameFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var sliderMax: Double {
        let max = fanSnapshot.globalMaxSpeed
        return Double(max > 0 ? max : FanRPMLimits.fallbackMax)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                TextField(localization.string("settings.custom.namePlaceholder", defaultValue: "预设名称"), text: $nameText)
                    .textFieldStyle(.plain)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isNameFocused
                                  ? PluginSettingsTheme.Palette.nativeFieldBackground
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isNameFocused
                                    ? Color(nsColor: .controlAccentColor)
                                    : isNameHovered
                                        ? PluginSettingsTheme.Palette.nativeSeparator
                                        : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .frame(maxWidth: 100)
                    .onHover { isNameHovered = $0 }
                    .focused($isNameFocused)
                    .onSubmit { onRename(nameText) }
                    .onChange(of: nameText) { _, new in
                        onRename(new)
                    }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(localization.string("settings.custom.deleteHelp", defaultValue: "删除此预设"))
            }

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Slider(
                    value: $sliderValue,
                    in: Double(FanRPMLimits.absoluteMin)...sliderMax,
                    step: 100
                ) {
                    EmptyView()
                } onEditingChanged: { editing in
                    if editing { resignFocus() }
                    if !editing { onRPMChange(Int(sliderValue)) }
                }

                Text("\(Int(sliderValue)) RPM")
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .contentShape(Rectangle())
        .onTapGesture { resignFocus() }
        // Sync external changes (e.g. from panel slider) back to local state
        .onChange(of: preset.strategy) { _, newStrategy in
            if case .fixed(let r) = newStrategy {
                sliderValue = Double(r)
            }
        }
        .onChange(of: preset.name) { _, newName in
            if nameText != newName { nameText = newName }
        }
    }
}
