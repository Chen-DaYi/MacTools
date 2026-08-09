import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct AutoInputSettingsView: View {
    @ObservedObject var store: AutoInputStore
    @ObservedObject var controller: AutoInputController
    let localization: PluginLocalization
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            behaviorSection
            rulesSection
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader(
                localization.string("settings.behavior.title", defaultValue: "切换行为"),
                icon: "character.cursor.ibeam"
            )

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
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                sectionHeader(
                    localization.string("settings.rules.title", defaultValue: "固定规则"),
                    icon: "app.badge.checkmark"
                )
                Spacer()
                Button(action: addApplication) {
                    Label(localization.string("settings.rules.add", defaultValue: "添加"), systemImage: "plus")
                        .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.sources.isEmpty)
            }

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
                .pluginSettingsCardBackground(.host)
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
        .pluginSettingsCardBackground(.host)
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

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func addApplication() {
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
            ?? controller.sources.first(where: { $0.id == currentInputSourceID })?.id
            ?? defaultSource.id
        store.upsertRule(AutoInputRule(
            bundleIdentifier: bundleIdentifier,
            displayName: url.deletingPathExtension().lastPathComponent,
            bundleURL: url,
            inputSourceID: sourceID
        ))
        onChange()
    }

    private var currentInputSourceID: String? {
        controller.currentSourceID
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
