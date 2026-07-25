import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

enum GeneralSettingsCardLayout {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let iconSize: CGFloat = 30
    static let iconCornerRadius: CGFloat = 8
    static let headerSpacing: CGFloat = 16
    static let minRowHeight: CGFloat = 38
}

struct SettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @StateObject private var uninstallConfirmationSession = PluginUninstallConfirmationSession()
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    var body: some View {
        // Recreate native AppKit-backed controls when the shared locale changes.
        let _ = runtimeLocale.revision

        return VStack(spacing: 0) {
            SettingsHistoryNavigationControls(coordinator: navigationCoordinator)

            TabView(selection: settingsDestinationBinding) {
                GeneralSettingsView(
                    pluginHost: pluginHost,
                    menuBarIconSettings: menuBarIconSettings,
                    menuBarIconGallery: menuBarIconGallery,
                    launchAtLoginController: launchAtLoginController
                )
                    .tag(SettingsDestination.general)
                    .tabItem {
                        Label(AppL10n.settings("tab.general", defaultValue: "通用"), systemImage: "gearshape")
                    }

                FeatureSettingsView(
                    pluginHost: pluginHost,
                    navigationCoordinator: navigationCoordinator,
                    uninstallConfirmationSession: uninstallConfirmationSession,
                    showDashboard: showDashboard,
                    showFeaturePanel: showFeaturePanel
                )
                    .tag(SettingsDestination.pluginConfiguration)
                    .tabItem {
                        Label(AppL10n.settings("tab.plugins", defaultValue: "插件"), systemImage: "slider.horizontal.3")
                    }

                AboutSettingsView(
                    appUpdater: appUpdater,
                    navigationCoordinator: navigationCoordinator
                )
                    .tag(SettingsDestination.about)
                    .tabItem {
                        Label(AppL10n.settings("tab.about", defaultValue: "关于"), systemImage: "info.circle")
                    }
            }
            .background {
                SettingsDestinationShortcutButtons(coordinator: navigationCoordinator)
            }
        }
        .id(runtimeLocale.revision)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
    }

    private var layoutDirection: LayoutDirection {
        PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    private var settingsDestinationBinding: Binding<SettingsDestination> {
        Binding(
            get: { navigationCoordinator.destination.settingsDestination },
            set: { destination in
                navigationCoordinator.selectSettingsDestination(destination)
            }
        )
    }
}

// AppWindowRouter hosts Settings in an AppKit NSWindow, so scene-level SwiftUI
// Commands are unavailable. These nonvisual buttons register window-local key
// equivalents while keeping the Settings layout and accessibility tree clean.
struct SettingsDestinationShortcutButtons: View {
    @ObservedObject var coordinator: SettingsNavigationCoordinator

    var body: some View {
        HStack(spacing: 0) {
            shortcutButton(for: .general, key: "1")
            shortcutButton(for: .pluginConfiguration, key: "2")
            shortcutButton(for: .about, key: "3")
            historyShortcutButton(key: "[") { coordinator.goBack() }
            historyShortcutButton(key: "]") { coordinator.goForward() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(
        for destination: SettingsDestination,
        key: KeyEquivalent
    ) -> some View {
        Button("") {
            coordinator.selectSettingsDestination(destination)
        }
        .keyboardShortcut(key, modifiers: [.command])
        .focusable(false)
    }

    private func historyShortcutButton(
        key: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: [.command])
            .focusable(false)
    }
}

struct SettingsHistoryNavigationControls: View {
    @ObservedObject var coordinator: SettingsNavigationCoordinator

    var body: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.goBack()
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!coordinator.canGoBack)
            .help(backTitle)

            Button {
                coordinator.goForward()
            } label: {
                Label(forwardTitle, systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!coordinator.canGoForward)
            .help(forwardTitle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(SettingsStyle.windowBackground)
    }

    private var backTitle: String {
        AppL10n.settings("navigation.back", defaultValue: "后退")
    }

    private var forwardTitle: String {
        AppL10n.settings("navigation.forward", defaultValue: "前进")
    }
}

private struct PermissionSettingsRow: View {
    let card: PluginPermissionCard
    let statusColor: Color
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: card.iconSystemImage)
                .pluginSettingsRowIconStyle(visualScale: card.iconVisualScale)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Text(card.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Label {
                        Text(card.statusText)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: card.statusSystemImage)
                    }
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(statusColor)
                }

                Text(card.description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote = card.footnote {
                    Text(footnote)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(card.buttonTitle, action: onAction)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearancePreferenceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var languagePreferenceRawValue = AppLanguagePreference.system.rawValue
    @AppStorage(MenuBarClickBehaviorPreference.userDefaultsKey) private var clickBehaviorRawValue = MenuBarClickBehaviorPreference.standard.rawValue

    var body: some View {
        Form {
            Section {
                LaunchAtLoginSettingsRow(controller: launchAtLoginController)
            } header: {
                Text(AppL10n.settings("general.section.startup", defaultValue: "启动"))
            }

            Section {
                AppearanceSettingsRow(selection: appearancePreferenceBinding)
                LanguageSettingsRow(selection: languagePreferenceBinding)
            } header: {
                Text(AppL10n.settings("general.section.appearance", defaultValue: "外观"))
            }

            Section {
                MenuBarIconSettingsView(
                    iconSettings: menuBarIconSettings,
                    gallery: menuBarIconGallery
                )
                MenuBarClickBehaviorSettingsRow(selection: clickBehaviorBinding)
            } header: {
                Text(AppL10n.settings("general.section.menuBarIcon", defaultValue: "状态栏图标"))
            }

            Section {
                AppShortcutSettingsRows(pluginHost: pluginHost)
            } header: {
                Text(AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"))
            }

            Section {
                PreferencesBackupSettingsRow(pluginHost: pluginHost)
            } header: {
                Text(AppL10n.preferencesBackup("general.section.preferencesBackup", defaultValue: "偏好设置备份"))
            }
        }
        .formStyle(.grouped)
    }

    private var appearancePreferenceBinding: Binding<AppAppearancePreference> {
        Binding {
            AppAppearancePreference(rawValue: appearancePreferenceRawValue) ?? .system
        } set: { preference in
            appearancePreferenceRawValue = preference.rawValue
            preference.apply()
        }
    }

    private var languagePreferenceBinding: Binding<AppLanguagePreference> {
        Binding {
            AppLanguagePreference(rawValue: languagePreferenceRawValue) ?? .system
        } set: { preference in
            let oldPreference = AppLanguagePreference(rawValue: languagePreferenceRawValue) ?? .system
            guard oldPreference != preference else {
                return
            }

            languagePreferenceRawValue = preference.rawValue
            preference.store()
        }
    }

    private var clickBehaviorBinding: Binding<MenuBarClickBehaviorPreference> {
        Binding {
            MenuBarClickBehaviorPreference(rawValue: clickBehaviorRawValue) ?? .standard
        } set: { preference in
            clickBehaviorRawValue = preference.rawValue
        }
    }
}

private struct AppShortcutSettingsRows: View {
    @ObservedObject var pluginHost: PluginHost

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(pluginHost.appShortcutItems.enumerated()), id: \.element.id) { index, item in
                AppShortcutSettingsRow(pluginHost: pluginHost, item: item)

                if index < pluginHost.appShortcutItems.count - 1 {
                    PluginSettingsListDivider()
                }
            }
        }
    }
}

private struct AppShortcutSettingsRow: View {
    private enum Layout {
        static let recorderWidth: CGFloat = 126
        static let actionButtonSize: CGFloat = 22
        static let controlSpacing = PluginSettingsTheme.Spacing.controlCluster
        static let controlClusterWidth = recorderWidth + controlSpacing + actionButtonSize
    }

    @ObservedObject var pluginHost: PluginHost
    let item: AppShortcutSettingsItem

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: item.systemImage)
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(item.errorMessage ?? item.description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(item.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Layout.controlSpacing) {
                PluginShortcutRecorder(
                    title: item.title,
                    displayText: item.bindingText,
                    minWidth: Layout.recorderWidth,
                    onRecord: { binding in
                        PluginShortcutRecordingResult.from(
                            errorMessage: pluginHost.setAppShortcutBindingAndReturnError(
                                binding,
                                for: item.action
                            )
                        )
                    },
                    onBeginRecording: {
                        pluginHost.clearAppShortcutError(item.action)
                    }
                )
                .frame(width: Layout.recorderWidth)

                if item.canClear {
                    Button {
                        pluginHost.clearAppShortcut(item.action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(PluginSettingsTheme.Typography.rowIcon)
                            .symbolRenderingMode(.monochrome)
                            .frame(
                                width: Layout.actionButtonSize,
                                height: Layout.actionButtonSize
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help(AppL10n.settings("shortcuts.clearHelp", defaultValue: "清除快捷键"))
                } else {
                    Color.clear
                        .frame(
                            width: Layout.actionButtonSize,
                            height: Layout.actionButtonSize
                        )
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Layout.controlClusterWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
    }
}

private struct PendingPreferencesImport: Identifiable {
    let id = UUID()
    let backup: PreferencesBackup
    let preview: PreferencesImportPreview
}

private struct PreferencesBackupSettingsRow: View {
    @ObservedObject var pluginHost: PluginHost
    @State private var pendingImport: PendingPreferencesImport?
    @State private var alertMessage: String?
    @State private var isPreparingImport = false
    @State private var isImporting = false

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "externaldrive.badge.checkmark")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.preferencesBackup("preferencesBackup.title", defaultValue: "导出与导入偏好设置"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.preferencesBackup(
                    "preferencesBackup.description",
                    defaultValue: "包含应用偏好、插件显示顺序、快捷键和支持导出的插件设置；不会包含权限、缓存、凭证或其他私有数据。"
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(AppL10n.preferencesBackup("preferencesBackup.export", defaultValue: "导出偏好设置…"), action: exportPreferences)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting)

                Button(AppL10n.preferencesBackup("preferencesBackup.import", defaultValue: "导入偏好设置…"), action: choosePreferencesImport)
                    .buttonStyle(.bordered)
                    .disabled(isPreparingImport || isImporting)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .sheet(item: $pendingImport) { pending in
            PreferencesImportPreviewSheet(
                preview: pending.preview,
                isImporting: isImporting,
                onCancel: { pendingImport = nil },
                onImport: { selectedPluginIDs in
                    importPreferences(
                        pending.backup,
                        installingMissingPluginIDs: selectedPluginIDs
                    )
                }
            )
        }
        .alert(
            AppL10n.preferencesBackup("preferencesBackup.alert.title", defaultValue: "偏好设置备份"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func exportPreferences() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PreferencesBackupExportFileName.make()
        panel.message = AppL10n.preferencesBackup("preferencesBackup.export.prompt", defaultValue: "将可移植的 MacTools 偏好设置保存为 JSON 文件。")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try pluginHost.makePreferencesBackup().encodedJSON().write(to: url, options: .atomic)
            alertMessage = AppL10n.preferencesBackup("preferencesBackup.exported", defaultValue: "偏好设置已导出。")
        } catch {
            alertMessage = preferencesBackupErrorMessage(error)
        }
    }

    private func choosePreferencesImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = AppL10n.preferencesBackup("preferencesBackup.import.prompt", defaultValue: "选择 MacTools 导出的偏好设置 JSON 文件。")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task { @MainActor in
            isPreparingImport = true
            defer { isPreparingImport = false }

            do {
                let backup = try await PreferencesBackup.decodeJSON(contentsOf: url)
                await pluginHost.refreshPluginCatalog()
                pendingImport = PendingPreferencesImport(
                    backup: backup,
                    preview: try pluginHost.preferencesImportPreview(for: backup)
                )
            } catch {
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func importPreferences(
        _ backup: PreferencesBackup,
        installingMissingPluginIDs pluginIDs: Set<String>
    ) {
        Task { @MainActor in
            isImporting = true
            defer { isImporting = false }

            do {
                let result = try await pluginHost.importPreferences(
                    backup,
                    installingMissingPluginIDs: pluginIDs
                )
                pendingImport = nil
                let importedMessage = AppL10n.preferencesBackup(
                    "preferencesBackup.imported",
                    defaultValue: "偏好设置已导入。"
                )
                let warnings = result.pluginInstallationFailures
                    .sorted { $0.key < $1.key }
                    .map { pluginID, message in
                        let title = pluginHost.pluginManagementItems
                            .first(where: { $0.id == pluginID })?
                            .title
                            ?? pluginID
                        return "\(title): \(message)"
                    }
                    + result.shortcutErrors
                        .values
                        .sorted()
                alertMessage = warnings.isEmpty
                    ? importedMessage
                    : ([importedMessage] + warnings).joined(separator: "\n")
            } catch {
                pendingImport = nil
                alertMessage = preferencesBackupErrorMessage(error)
            }
        }
    }

    private func preferencesBackupErrorMessage(_ error: Error) -> String {
        switch error as? PreferencesBackupError {
        case let .unsupportedFormatVersion(version):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.unsupportedFormat",
                defaultValue: "不支持的偏好设置备份版本（%d）。",
                version
            )
        case .invalidApplicationPreferences:
            return AppL10n.preferencesBackup(
                "preferencesBackup.error.invalidApplicationPreferences",
                defaultValue: "备份中的应用偏好设置无效。"
            )
        case let .fileTooLarge(maximumBytes):
            return AppL10n.preferencesBackupFormat(
                "preferencesBackup.error.fileTooLarge",
                defaultValue: "偏好设置备份不能超过 %d MB。",
                maximumBytes / (1024 * 1024)
            )
        case nil:
            return error.localizedDescription
        }
    }
}

enum PreferencesBackupExportFileName {
    static func make(date: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "MacTools Preferences \(formatter.string(from: date)).json"
    }
}

private struct PreferencesImportPreviewSheet: View {
    let preview: PreferencesImportPreview
    let isImporting: Bool
    let onCancel: () -> Void
    let onImport: (Set<String>) -> Void
    @State private var selectedInstallablePluginIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppL10n.preferencesBackup("preferencesBackup.preview.title", defaultValue: "导入偏好设置"))
                .font(PluginSettingsTheme.Typography.pageTitle)

            Text(previewDescription)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text(AppL10n.preferencesBackup("preferencesBackup.preview.application", defaultValue: "应用偏好"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.applicationSummary",
                        defaultValue: "应用外观、语言和状态栏点击行为"
                    ))
                }
                GridRow {
                    Text(AppL10n.preferencesBackup("preferencesBackup.preview.plugins", defaultValue: "插件设置"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(AppL10n.preferencesBackupFormat(
                        "preferencesBackup.preview.pluginsCount",
                        defaultValue: "%d 个可用插件",
                        preview.pluginCount
                    ))
                }
                GridRow {
                    Text(AppL10n.preferencesBackup("preferencesBackup.preview.shortcuts", defaultValue: "快捷键"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(AppL10n.preferencesBackupFormat(
                        "preferencesBackup.preview.shortcutsCount",
                        defaultValue: "%d 项自定义",
                        preview.shortcutCount
                    ))
                }
            }
            .font(PluginSettingsTheme.Typography.rowDescription)

            Text(AppL10n.preferencesBackup(
                "preferencesBackup.preview.replaceNotice",
                defaultValue: "将替换以上偏好类别；备份中未包含的设置会恢复为默认值。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !preview.installablePlugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.installablePlugins",
                        defaultValue: "可安装的缺失插件"
                    ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(AppL10n.preferencesBackup(
                        "preferencesBackup.preview.installablePluginsDescription",
                        defaultValue: "仅会从已验证的插件列表下载你选中的插件。"
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(preview.installablePlugins) { plugin in
                        Toggle(isOn: installationSelectionBinding(for: plugin.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.title)
                                    .font(PluginSettingsTheme.Typography.rowTitle)

                                Text("\(plugin.version) · \(plugin.summary ?? plugin.id)")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            if !preview.unavailablePluginIDs.isEmpty || !preview.unavailableShortcutIDs.isEmpty {
                Text(AppL10n.preferencesBackupFormat(
                    "preferencesBackup.preview.skipped",
                    defaultValue: "将跳过 %d 个本机不可用的插件设置和 %d 项快捷键；不会安装缺失插件。",
                    preview.unavailablePluginIDs.count,
                    preview.unavailableShortcutIDs.count
                ))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppL10n.settings("common.cancel", defaultValue: "取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .disabled(isImporting)
                Button(confirmTitle) {
                    onImport(selectedInstallablePluginIDs)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
            }

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var confirmTitle: String {
        if selectedInstallablePluginIDs.isEmpty {
            return AppL10n.preferencesBackup("preferencesBackup.preview.confirm", defaultValue: "导入")
        }

        return AppL10n.preferencesBackup(
            "preferencesBackup.preview.installAndImport",
            defaultValue: "安装所选插件并导入"
        )
    }

    private var previewDescription: String {
        if selectedInstallablePluginIDs.isEmpty {
            return AppL10n.preferencesBackup(
                "preferencesBackup.preview.description",
                defaultValue: "请确认以下更改。导入不会安装插件，也不会修改权限、缓存、Keychain 密钥或插件私有数据。"
            )
        }

        return AppL10n.preferencesBackup(
            "preferencesBackup.description",
            defaultValue: "备份包含应用偏好、插件显示顺序和快捷键；不会包含权限、缓存或插件私有数据。"
        )
    }

    private func installationSelectionBinding(for pluginID: String) -> Binding<Bool> {
        Binding {
            selectedInstallablePluginIDs.contains(pluginID)
        } set: { isSelected in
            if isSelected {
                selectedInstallablePluginIDs.insert(pluginID)
            } else {
                selectedInstallablePluginIDs.remove(pluginID)
            }
        }
    }
}

private struct MenuBarClickBehaviorSettingsRow: View {
    @Binding var selection: MenuBarClickBehaviorPreference
    @State private var toggleID = UUID()

    private var isSwapped: Binding<Bool> {
        Binding {
            selection.isSwapped
        } set: { enabled in
            selection = enabled ? .swapped : .standard
        }
    }

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "cursorarrow.click.2")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("menuBarClick.title", defaultValue: "交换左键与右键功能"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("menuBarClick.description", defaultValue: "关闭时左键打开仪表盘、右键功能打开功能面板；开启后互换。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppL10n.settings(
                    "menuBarClick.rightClickShortcutNotice",
                    defaultValue: "可以使用 Option + 左键触发右键功能。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(AppL10n.settings("menuBarClick.toggle", defaultValue: "交换左键与右键功能"), isOn: isSwapped)
                .toggleStyle(.switch)
                .labelsHidden()
                .id(toggleID)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("menuBarClick.help", defaultValue: "开启后左键打开功能面板，右键功能打开仪表盘"))
        .onAppear {
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
    }
}

private struct AppearanceSettingsRow: View {
    @Binding var selection: AppAppearancePreference

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "circle.lefthalf.filled")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("appearance.title", defaultValue: "应用外观"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("appearance.description", defaultValue: "自动跟随系统，也可以固定为深色或浅色。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppL10n.settings("appearance.picker", defaultValue: "外观"), selection: $selection) {
                ForEach(AppAppearancePreference.allCases) { preference in
                    Text(preference.title)
                        .tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("appearance.help", defaultValue: "设置应用外观"))
    }
}

private struct LanguageSettingsRow: View {
    @Binding var selection: AppLanguagePreference

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "globe")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("language.title", defaultValue: "语言"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(AppL10n.settings("language.description", defaultValue: "默认跟随系统语言，也可以固定为指定语言。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(AppL10n.settings("language.picker", defaultValue: "语言"), selection: $selection) {
                ForEach(AppLanguagePreference.allCases) { preference in
                    Text(preference.pickerTitle)
                        .tag(preference)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("language.help", defaultValue: "设置应用语言"))
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @ObservedObject var controller: LaunchAtLoginController
    @State private var toggleID = UUID()

    var body: some View {
        HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: "power")
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.settings("launchAtLogin.title", defaultValue: "开机时启动"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(controller.lastErrorMessage == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(AppL10n.settings("launchAtLogin.toggle", defaultValue: "开机时启动 MacTools"), isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .id(toggleID)
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .help(AppL10n.settings("launchAtLogin.help", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。"))
        .onAppear {
            DispatchQueue.main.async {
                toggleID = UUID()
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            controller.isEnabled
        } set: { newValue in
            controller.setEnabled(newValue)
        }
    }

    private var subtitle: String {
        controller.lastErrorMessage ?? AppL10n.settings("launchAtLogin.description", defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。")
    }
}

private struct FeatureSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            FeatureSettingsSidebar(
                configurationItems: pluginHost.pluginConfigurationItems,
                selection: selectionBinding
            )
            .frame(width: 220)

            FeatureSettingsDetailPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                selectedPane: selectedPane,
                uninstallConfirmationSession: uninstallConfirmationSession,
                showDashboard: showDashboard,
                showFeaturePanel: showFeaturePanel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsStyle.windowBackground)
        .onChange(of: pluginHost.pluginConfigurationItems.map(\.id)) {
            navigationCoordinator.reconcileCurrentDestinationAvailability()
        }
    }

    private var selectionBinding: Binding<FeatureSettingsPane> {
        Binding {
            selectedPane
        } set: { selection in
            navigationCoordinator.navigate(to: .plugins(selection))
        }
    }

    private var selectedPane: FeatureSettingsPane {
        navigationCoordinator.destination.featureSettingsPane
            ?? pluginHost.pluginSettingsLandingPage()
    }
}

private struct FeatureSettingsSidebar: View {
    let configurationItems: [PluginConfigurationItem]
    @Binding var selection: FeatureSettingsPane

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                FeatureSettingsSidebarSectionTitle(AppL10n.settings(
                    "plugins.sidebar.pluginsSection",
                    defaultValue: "插件"
                ))
                    .padding(.top, 14)

                FeatureSettingsSidebarRow(
                    title: AppL10n.settings("plugins.sidebar.dashboard", defaultValue: "仪表盘"),
                    systemImage: "square.grid.2x2",
                    iconTint: .blue,
                    isSelected: selection == .dashboardLayout
                ) {
                    selection = .dashboardLayout
                }

                FeatureSettingsSidebarRow(
                    title: AppL10n.settings("plugins.sidebar.featurePanel", defaultValue: "功能面板"),
                    systemImage: "switch.2",
                    iconTint: .purple,
                    isSelected: selection == .featurePanelLayout
                ) {
                    selection = .featurePanelLayout
                }

                FeatureSettingsSidebarRow(
                    title: AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "市场"),
                    systemImage: "shippingbox",
                    iconTint: .blue,
                    isSelected: selection == .marketplace
                ) {
                    selection = .marketplace
                }

                FeatureSettingsSidebarSectionTitle(AppL10n.settings("plugins.sidebar.configurationSection", defaultValue: "插件设置"))
                    .padding(.top, 16)

                if configurationItems.isEmpty {
                    Text(AppL10n.settings("plugins.sidebar.emptyConfigurations", defaultValue: "暂无可设置插件"))
                        .font(PluginSettingsTheme.Typography.secondaryLabel)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    ForEach(configurationItems) { item in
                        FeatureSettingsSidebarRow(
                            title: item.title,
                            systemImage: item.iconName,
                            iconTint: item.iconTint,
                            isSelected: selection == .configuration(item.id)
                        ) {
                            selection = .configuration(item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsStyle.sidebarBackground)
    }
}

private struct FeatureSettingsSidebarSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct FeatureSettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    Image(systemName: systemImage)
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(isSelected ? Color.accentColor : iconTint)
                        .frame(width: 18, height: 18)

                    Text(title)
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }

    private var rowBackground: Color {
        if isSelected {
            return SettingsStyle.sidebarSelectionBackground
        }

        return isHovered ? SettingsStyle.sidebarHoverBackground : .clear
    }
}

private struct FeatureSettingsDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let selectedPane: FeatureSettingsPane
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void

    var body: some View {
        detail
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .dashboardLayout:
            SurfaceLayoutSettingsView(
                surface: .dashboard,
                title: AppL10n.settings("plugins.dashboard.title", defaultValue: "仪表盘"),
                description: AppL10n.settings(
                    "plugins.dashboard.description",
                    defaultValue: "拖拽调整仪表盘组件的排列顺序。"
                ),
                systemImage: "square.grid.2x2",
                iconTint: .blue,
                items: pluginHost.dashboardLayoutItems,
                hiddenItems: pluginHost.dashboardHiddenLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.dashboard.open", defaultValue: "打开仪表盘"),
                emptyTitle: AppL10n.settings("plugins.dashboard.empty.title", defaultValue: "暂无仪表盘组件"),
                emptyDescription: AppL10n.settings(
                    "plugins.dashboard.empty.description",
                    defaultValue: "已安装且支持仪表盘的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .dashboard)
                },
                onSetVisible: { pluginID, isVisible in
                    pluginHost.setPluginVisible(isVisible, id: pluginID, on: .dashboard)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .dashboard) },
                onOpenPanel: showDashboard,
                configurationPluginIDs: Set(pluginHost.pluginConfigurationItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginConfiguration(pluginID:),
                onOpenMarketplace: pluginHost.presentPluginMarketplace,
                onUninstall: { pluginID in
                    try pluginHost.uninstallDynamicPlugin(pluginID: pluginID)
                }
            )
        case .featurePanelLayout:
            SurfaceLayoutSettingsView(
                surface: .featurePanel,
                title: AppL10n.settings("plugins.featurePanel.title", defaultValue: "功能面板"),
                description: AppL10n.settings(
                    "plugins.featurePanel.description",
                    defaultValue: "拖拽调整功能面板操作的排列顺序。"
                ),
                systemImage: "switch.2",
                iconTint: .purple,
                items: pluginHost.featurePanelLayoutItems,
                hiddenItems: pluginHost.featurePanelHiddenLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.featurePanel.open", defaultValue: "打开功能面板"),
                emptyTitle: AppL10n.settings("plugins.featurePanel.empty.title", defaultValue: "暂无功能面板操作"),
                emptyDescription: AppL10n.settings(
                    "plugins.featurePanel.empty.description",
                    defaultValue: "已安装且支持功能面板的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .featurePanel)
                },
                onSetVisible: { pluginID, isVisible in
                    pluginHost.setPluginVisible(isVisible, id: pluginID, on: .featurePanel)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .featurePanel) },
                onOpenPanel: showFeaturePanel,
                configurationPluginIDs: Set(pluginHost.pluginConfigurationItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginConfiguration(pluginID:),
                onOpenMarketplace: pluginHost.presentPluginMarketplace,
                onUninstall: { pluginID in
                    try pluginHost.uninstallDynamicPlugin(pluginID: pluginID)
                }
            )
        case .marketplace:
            PluginManagementSettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                uninstallConfirmationSession: uninstallConfirmationSession
            )
        case let .configuration(pluginID):
            PluginConfigurationDetailPane(
                pluginHost: pluginHost,
                item: configurationItem(for: pluginID)
            )
        }
    }

    private func configurationItem(for pluginID: String) -> PluginConfigurationItem? {
        pluginHost.pluginConfigurationItems.first { $0.id == pluginID }
    }
}

private struct SurfaceLayoutSettingsView: View {
    let surface: PluginDisplaySurface
    let title: String
    let description: String
    let systemImage: String
    let iconTint: Color
    let items: [PluginSurfaceLayoutItem]
    let hiddenItems: [PluginSurfaceLayoutItem]
    let openButtonTitle: String
    let emptyTitle: String
    let emptyDescription: String
    let onMove: (String, Int) -> Void
    let onSetVisible: (String, Bool) -> Void
    let onResetOrder: () -> Void
    let onOpenPanel: () -> Void
    let configurationPluginIDs: Set<String>
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let onOpenSettings: (String) -> Void
    let onOpenMarketplace: () -> Void
    let onUninstall: (String) throws -> Void
    @State private var pendingUninstallItem: PluginUninstallConfirmation?
    @State private var uninstallErrorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    SettingsPageHeader(
                        title: title,
                        description: description,
                        systemImage: systemImage,
                        iconTint: iconTint
                    )

                    Button(AppL10n.settings(
                        "plugins.layout.restoreDefaultOrder",
                        defaultValue: "恢复默认排列"
                    ), action: onResetOrder)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(items.count < 2)

                    Button(action: onOpenPanel) {
                        Label(openButtonTitle, systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if uninstallConfirmationSession.isConfirmationPaused {
                    PluginUninstallConfirmationPausedBanner(session: uninstallConfirmationSession)
                }

                SettingsCardContainer {
                    if items.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: systemImage,
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        FeatureManagementTableView(
                            items: items.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            onMove: onMove,
                            onSetVisible: onSetVisible,
                            onOpenSettings: onOpenSettings,
                            onOpenMarketplace: onOpenMarketplace,
                            onRequestUninstall: requestUninstall
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: items.count))
                    }
                }

                if !hiddenItems.isEmpty {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        Label(hiddenSectionTitle, systemImage: "eye.slash")
                            .font(PluginSettingsTheme.Typography.sectionTitle)
                            .foregroundStyle(.secondary)

                        SettingsCardContainer {
                            FeatureManagementTableView(
                                items: hiddenItems.map {
                                    FeatureManagementTableItem(
                                        surfaceItem: $0,
                                        hasSettings: configurationPluginIDs.contains($0.id)
                                    )
                                },
                                mode: .surface(surface),
                                isReorderEnabled: false,
                                onSetVisible: onSetVisible,
                                onOpenSettings: onOpenSettings,
                                onOpenMarketplace: onOpenMarketplace,
                                onRequestUninstall: requestUninstall
                            )
                            .frame(height: FeatureManagementTableView.preferredHeight(for: hiddenItems.count))
                        }
                    }
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SettingsStyle.contentBackground)
        .sheet(item: $pendingUninstallItem) { item in
            PluginUninstallConfirmationSheet(
                confirmation: item,
                session: uninstallConfirmationSession,
                onConfirm: uninstall
            )
        }
        .alert(
            AppL10n.plugins("plugin.marketplace.operationFailed.title", defaultValue: "插件操作失败"),
            isPresented: Binding(
                get: { uninstallErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        uninstallErrorMessage = nil
                    }
                }
            )
        ) {
            Button(AppL10n.settings("common.ok", defaultValue: "好"), role: .cancel) {}
        } message: {
            Text(uninstallErrorMessage ?? "")
        }
    }

    private func requestUninstall(_ pluginID: String) {
        guard let item = (items + hiddenItems).first(where: { $0.id == pluginID && $0.canUninstall }) else {
            return
        }

        let confirmation = PluginUninstallConfirmation(
            pluginID: item.id,
            pluginTitle: item.title,
            surfaceCapabilitySummary: pluginCapabilitySummary(item.capabilities)
        )
        if uninstallConfirmationSession.shouldConfirmUninstall {
            pendingUninstallItem = confirmation
        } else {
            uninstall(confirmation)
        }
    }

    private var hiddenSectionTitle: String {
        switch surface {
        case .dashboard:
            return AppL10n.settingsFormat(
                "plugins.dashboard.hiddenSectionFormat",
                defaultValue: "已在仪表盘隐藏（%d）",
                hiddenItems.count
            )
        case .featurePanel:
            return AppL10n.settingsFormat(
                "plugins.featurePanel.hiddenSectionFormat",
                defaultValue: "已在功能面板隐藏（%d）",
                hiddenItems.count
            )
        }
    }

    private func uninstall(_ confirmation: PluginUninstallConfirmation) {
        do {
            try onUninstall(confirmation.pluginID)
        } catch {
            uninstallErrorMessage = error.localizedDescription
        }
    }
}

private struct SettingsCardContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsCardBackground(.host)
    }
}

private struct PluginConfigurationDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginConfigurationItem?

    var body: some View {
        Group {
            if let item {
                if item.prefersFullHeight {
                    VStack(alignment: .leading, spacing: 0) {
                        PluginConfigurationHeader(item: item)
                            .padding(PluginSettingsTheme.Spacing.pagePadding)

                        if item.hasCustomConfiguration {
                            pluginHost.pluginConfigurationViewItem(for: item.pluginID).content
                                .padding(.horizontal, PluginSettingsTheme.Spacing.pagePadding)
                                .padding(.bottom, PluginSettingsTheme.Spacing.pagePadding)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            PluginConfigurationHeader(item: item)

                            if !item.settingsCards.isEmpty {
                                PluginSettingsCardSection(
                                    pluginHost: pluginHost,
                                    cards: item.settingsCards
                                )
                            }

                            if !item.permissionCards.isEmpty {
                                PluginPermissionCardSection(
                                    pluginHost: pluginHost,
                                    cards: item.permissionCards
                                )
                            }

                            if item.hasCustomConfiguration {
                                pluginHost.pluginConfigurationViewItem(for: item.pluginID).content
                            }

                            if !item.shortcutItems.isEmpty {
                                PluginShortcutSection(pluginHost: pluginHost, items: item.shortcutItems)
                            }
                        }
                        .padding(PluginSettingsTheme.Spacing.pagePadding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(SettingsStyle.contentBackground)
                }
            } else {
                ContentUnavailableView(
                    AppL10n.settings("plugins.configuration.empty.title", defaultValue: "暂无可配置插件"),
                    systemImage: "slider.horizontal.3",
                    description: Text(AppL10n.settings(
                        "plugins.configuration.empty.description",
                        defaultValue: "当插件提供权限、快捷键或自定义设置后，会显示在这里。"
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SettingsStyle.contentBackground)
    }
}

private struct PluginConfigurationHeader: View {
    let item: PluginConfigurationItem

    var body: some View {
        SettingsPageHeader(
            title: item.title,
            description: item.description,
            systemImage: item.iconName,
            iconTint: item.iconTint
        )
        .padding(.bottom, 2)
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let description: String
    let systemImage: String
    let iconTint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconTint.opacity(0.14))

                Image(systemName: systemImage)
                    .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: PluginSettingsTheme.Size.pageIcon, height: PluginSettingsTheme.Size.pageIcon)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.pageTitle)

                Text(description)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PluginSettingsCardSection: View {
    @ObservedObject var pluginHost: PluginHost
    let cards: [PluginSettingsCard]

    var body: some View {
        PluginConfigurationSection(title: AppL10n.settings("plugins.configuration.section.settings", defaultValue: "设置"), systemImage: "switch.2") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    PluginSettingsCardRow(
                        card: card,
                        statusColor: statusColor(for: card.statusTone),
                        onAction: {
                            if let actionID = card.actionID {
                                pluginHost.performSettingsAction(pluginID: card.pluginID, actionID: actionID)
                            }
                        }
                    )

                    if index < cards.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }
}

private struct PluginSettingsCardRow: View {
    let card: PluginSettingsCard
    let statusColor: Color
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(card.title)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)

                    Text(card.description)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Label {
                    Text(card.statusText)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: card.statusSystemImage)
                }
                .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                .foregroundStyle(statusColor)
            }

            if let footnote = card.footnote {
                Text(footnote)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let buttonTitle = card.buttonTitle, card.actionID != nil {
                HStack {
                    Spacer()

                    Button(buttonTitle, action: onAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
    }
}

private struct PluginPermissionCardSection: View {
    @ObservedObject var pluginHost: PluginHost
    let cards: [PluginPermissionCard]

    var body: some View {
        PluginConfigurationSection(title: AppL10n.settings("plugins.configuration.section.permissions", defaultValue: "权限"), systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    PermissionSettingsRow(
                        card: card,
                        statusColor: statusColor(for: card.statusTone),
                        onAction: {
                            pluginHost.performPermissionAction(
                                pluginID: card.pluginID,
                                permissionID: card.permissionID
                            )
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if index < cards.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }
}

private struct PluginShortcutSection: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]

    var body: some View {
        PluginConfigurationSection(title: AppL10n.settings("plugins.configuration.section.shortcuts", defaultValue: "快捷键"), systemImage: "command") {
            VStack(alignment: .leading, spacing: 0) {
                if groupedItems.isEmpty {
                    ShortcutSettingsRowsView(pluginHost: pluginHost, items: items)
                } else {
                    GroupedShortcutSettingsRowsView(pluginHost: pluginHost, groups: groupedItems)
                }
            }
        }
    }

    private var groupedItems: [ShortcutSettingsGroup] {
        guard items.allSatisfy({ $0.settingsGroupID != nil }) else {
            return []
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]

        for item in items {
            guard let groupID = item.settingsGroupID else {
                continue
            }

            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(item)
        }

        return groupOrder.compactMap { groupID in
            guard let groupItems = groups[groupID], let firstItem = groupItems.first else { return nil }

            return ShortcutSettingsGroup(
                id: groupID,
                title: firstItem.settingsGroupTitle ?? firstItem.title,
                description: firstItem.settingsGroupDescription ?? firstItem.description,
                items: groupItems
            )
        }
    }
}

private struct PluginConfigurationSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(title, systemImage: systemImage)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            SettingsCardContainer {
                content
            }
        }
    }
}

private func statusColor(for tone: PluginStatusTone) -> Color {
    switch tone {
    case .neutral:
        return .secondary
    case .positive:
        return .green
    case .caution:
        return .orange
    }
}

struct AboutSettingsView: View {
    @StateObject private var updateViewModel: AboutUpdateViewModel
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator

    init(
        appUpdater: AppUpdater,
        navigationCoordinator: SettingsNavigationCoordinator
    ) {
        _updateViewModel = StateObject(
            wrappedValue: AboutUpdateViewModel(updater: appUpdater)
        )
        self.navigationCoordinator = navigationCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            AppIconPreview()

            Text(AppMetadata.appName)
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 8)

            Text(AppL10n.settingsFormat("about.versionFormat", defaultValue: "版本 %@", AppMetadata.versionDescription))
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            AboutUpdateCard(viewModel: updateViewModel)
                .padding(.top, 28)
                .frame(maxWidth: 420)

            Text(AppMetadata.aboutDescription)
                .font(.title3)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 28)

            VStack(spacing: 0) {
                Link(AppMetadata.repositoryDisplayName, destination: AppMetadata.repositoryURL)
                    .font(.title3)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .onChange(
            of: navigationCoordinator.aboutUpdateActionRequest,
            initial: true
        ) { _, request in
            handleUpdateActionRequest(request)
        }
    }

    private func handleUpdateActionRequest(_ request: AboutUpdateActionRequest?) {
        guard
            let request,
            navigationCoordinator.consumeAboutUpdateActionRequest(request)
        else {
            return
        }

        Task { @MainActor in
            await Task.yield()
            updateViewModel.performAvailableUpdateAction(version: request.version)
        }
    }
}

private struct AboutUpdateCard: View {
    private enum Layout {
        static let verticalSpacing: CGFloat = 12
        static let statusMinHeight: CGFloat = 16
    }

    @ObservedObject var viewModel: AboutUpdateViewModel

    var body: some View {
        VStack(spacing: Layout.verticalSpacing) {
            Button(viewModel.primaryButtonTitle) {
                Task {
                    await viewModel.performPrimaryAction()
                }
            }
            .buttonStyle(AboutUpdatePrimaryButtonStyle())
            .disabled(viewModel.isPrimaryButtonDisabled)

            Text(statusText ?? " ")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(viewModel.statusColor)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: Layout.statusMinHeight, alignment: .top)
                .opacity(statusText == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String? {
        switch viewModel.state {
        case .idle:
            return nil
        default:
            return viewModel.statusDetail ?? viewModel.statusHeadline
        }
    }
}

private struct AboutUpdatePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PluginSettingsTheme.Typography.rowTitle)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: 92)
            .background(
                Capsule(style: .continuous)
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        let baseOpacity: CGFloat = isEnabled ? 1 : 0.45
        let pressedOpacity: CGFloat = isEnabled ? 0.82 : baseOpacity
        return Color.accentColor.opacity(isPressed ? pressedOpacity : baseOpacity)
    }
}

private struct AppIconPreview: View {
    private static let iconSize: CGFloat = 82

    var body: some View {
        if let appIcon = AppMetadata.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "wrench.and.screwdriver.fill")
                .resizable()
                .scaledToFit()
                .padding(12)
                .foregroundStyle(.secondary)
                .background(PluginSettingsTheme.Palette.nativeCardBackground)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
