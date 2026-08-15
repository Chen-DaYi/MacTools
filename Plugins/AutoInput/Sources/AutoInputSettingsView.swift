import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct AutoInputSettingsView: View {
    enum SectionKind {
        case behavior
        case rules
    }

    @ObservedObject var store: AutoInputStore
    @ObservedObject var controller: AutoInputController
    let localization: PluginLocalization
    let onChange: () -> Void
    let onHUDChange: (Bool) -> Void
    let section: SectionKind

    @ViewBuilder
    var body: some View {
        switch section {
        case .behavior:
            behaviorSection
        case .rules:
            rulesSection
        }
    }

    private var behaviorSection: some View {
        VStack(spacing: 0) {
            settingToggle(
                icon: "arrow.counterclockwise",
                title: localization.string("settings.memory.title", defaultValue: "自动记忆"),
                description: localization.string(
                    "settings.memory.description",
                    defaultValue: "切回应用时恢复上次使用的输入法。"
                ),
                isOn: Binding(
                    get: { store.remembersLastInputSource },
                    set: { value in
                        store.setRemembersLastInputSource(value)
                        onChange()
                    }
                )
            )
            PluginSettingsListDivider()
            settingToggle(
                icon: "text.cursor",
                title: localization.string("settings.hud.title", defaultValue: "输入法提示"),
                description: localization.string(
                    "settings.hud.description",
                    defaultValue: "聚焦文本输入区域或终端时，在附近短暂显示当前输入法。需要辅助功能权限。"
                ),
                isOn: Binding(
                    get: { store.isInputHUDEnabled },
                    set: { value in
                        guard store.setInputHUDEnabled(value) == .committed else {
                            onChange()
                            return
                        }
                        onHUDChange(value)
                    }
                )
            )
            if store.isInputHUDEnabled {
                PluginSettingsListDivider()
                hudSizePicker
                PluginSettingsListDivider()
                hudPositionPicker
            }
        }
    }

    private var hudSizePicker: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "textformat.size")
                    .pluginSettingsRowIconStyle()
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(localization.string("settings.hud.size.title", defaultValue: "提示大小"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(localization.string(
                        "settings.hud.size.description",
                        defaultValue: "调整提示的文字和面板大小。"
                    ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: Binding(
                    get: { store.inputHUDSize },
                    set: { value in
                        store.setInputHUDSize(value)
                        onChange()
                    }
                )) {
                    ForEach(AutoInputHUDSize.allCases) { size in
                        Text(localizedHUDSize(size)).tag(size)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 130, idealWidth: 160, maxWidth: 190)
                .accessibilityIdentifier("auto-input.hud-size")
            }

            HStack {
                Spacer(minLength: 0)
                InputSourceHUDPreview(
                    title: hudPreviewSourceName,
                    size: store.inputHUDSize
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .pluginSettingsCardBackground(.recessed)
            .accessibilityHidden(true)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var hudPreviewSourceName: String {
        controller.sources.first(where: { $0.id == controller.currentSourceID })?.name
            ?? controller.sources.first?.name
            ?? "ABC"
    }

    private var hudPositionPicker: some View {
        settingPickerRow(
            icon: "rectangle.and.hand.point.up.left",
            title: localization.string("settings.hud.position.title", defaultValue: "提示位置"),
            description: localization.string(
                "settings.hud.position.description",
                defaultValue: "选择提示显示在当前输入区域附近或所在显示器中央。"
            )
        ) {
            Picker("", selection: Binding(
                get: { store.inputHUDPosition },
                set: { value in
                    store.setInputHUDPosition(value)
                    onChange()
                }
            )) {
                ForEach(AutoInputHUDPosition.allCases) { position in
                    Text(localizedHUDPosition(position)).tag(position)
                }
            }
            .labelsHidden()
            .frame(minWidth: 150, idealWidth: 180, maxWidth: 220)
            .accessibilityIdentifier("auto-input.hud-position")
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        if store.rules.isEmpty {
            emptyRulesView
        } else {
            VStack(spacing: 0) {
                ForEach(store.rules) { rule in
                    ruleRow(rule)
                    if rule.id != store.rules.last?.id {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }

    private var emptyRulesView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string(
                    "settings.rules.empty",
                    defaultValue: "添加应用，为它指定固定输入法"
                ))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
    }

    private func ruleRow(_ rule: AutoInputRule) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(nsImage: applicationIcon(for: rule))
                .resizable()
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(rule.displayName)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
                Text(ruleSubtitle(rule))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundColor(isSourceAvailable(rule.inputSourceID) ? .secondary : .red)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: Binding(
                get: { rule.inputSourceID },
                set: { sourceID in
                    store.updateRule(bundleIdentifier: rule.bundleIdentifier, inputSourceID: sourceID)
                    onChange()
                }
            )) {
                if !isSourceAvailable(rule.inputSourceID) {
                    Text(localization.string("settings.source.unavailable", defaultValue: "输入法不可用"))
                        .tag(rule.inputSourceID)
                }
                ForEach(controller.sources) { source in
                    Text(source.name).tag(source.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, idealWidth: 190, maxWidth: 240)

            Button {
                store.removeRule(bundleIdentifier: rule.bundleIdentifier)
                onChange()
            } label: {
                Image(systemName: "trash")
                    .pluginSettingsRowIconStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(localization.string("settings.rules.delete", defaultValue: "删除此规则"))
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func settingToggle(
        icon: String,
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
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
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func settingPickerRow<Control: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func localizedHUDSize(_ size: AutoInputHUDSize) -> String {
        switch size {
        case .compact:
            localization.string("settings.hud.size.compact", defaultValue: "紧凑")
        case .standard:
            localization.string("settings.hud.size.standard", defaultValue: "标准")
        case .large:
            localization.string("settings.hud.size.large", defaultValue: "大")
        }
    }

    private func localizedHUDPosition(_ position: AutoInputHUDPosition) -> String {
        switch position {
        case .automatic:
            localization.string("settings.hud.position.automatic", defaultValue: "自动")
        case .above:
            localization.string("settings.hud.position.above", defaultValue: "优先显示在上方")
        case .below:
            localization.string("settings.hud.position.below", defaultValue: "优先显示在下方")
        case .screenCenter:
            localization.string("settings.hud.position.screen-center", defaultValue: "屏幕中央")
        }
    }

    static func addApplication(
        store: AutoInputStore,
        controller: AutoInputController,
        localization: PluginLocalization,
        onChange: () -> Void
    ) {
        guard let defaultSource = controller.sources.first else { return }
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择要自动切换输入法的应用")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return }

        let existingSourceID = store.rule(for: bundleIdentifier)?.inputSourceID
        let sourceID = existingSourceID
            ?? controller.sources.first(where: { $0.id == controller.currentSourceID })?.id
            ?? defaultSource.id
        store.upsertRule(AutoInputRule(
            bundleIdentifier: bundleIdentifier,
            displayName: url.deletingPathExtension().lastPathComponent,
            bundleURL: url,
            inputSourceID: sourceID
        ))
        onChange()
    }

    private func applicationIcon(for rule: AutoInputRule) -> NSImage {
        guard let url = rule.bundleURL else {
            return NSWorkspace.shared.icon(forFile: "/Applications")
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    private func ruleSubtitle(_ rule: AutoInputRule) -> String {
        guard isSourceAvailable(rule.inputSourceID) else {
            return localization.string("settings.source.unavailable", defaultValue: "输入法不可用")
        }
        return rule.bundleIdentifier
    }

    private func isSourceAvailable(_ id: String) -> Bool {
        controller.sources.contains { $0.id == id }
    }
}
