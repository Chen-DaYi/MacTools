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
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    let appearanceUserDefaults: UserDefaults
    @StateObject private var uninstallConfirmationSession = PluginUninstallConfirmationSession()
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    var body: some View {
        // Recreate native AppKit-backed controls when the shared locale changes.
        let _ = runtimeLocale.revision
        let orderedPluginPanes = FeatureSettingsPane.settingsSidebarOrder(
            configurationIDs: pluginHost.pluginSettingsItems.map(\.id)
        )

        return ZStack {
            TabView(selection: settingsDestinationBinding) {
                GeneralSettingsView(
                    pluginHost: pluginHost,
                    navigationCoordinator: navigationCoordinator,
                    menuBarIconSettings: menuBarIconSettings,
                    menuBarIconGallery: menuBarIconGallery,
                    launchAtLoginController: launchAtLoginController,
                    menuBarPanelThemeStore: menuBarPanelThemeStore,
                    appearanceUserDefaults: appearanceUserDefaults
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
                    showFeaturePanel: showFeaturePanel,
                    orderedPanes: orderedPluginPanes
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
            .blur(
                radius: navigationCoordinator.isUnifiedSearchPresented
                    && !accessibilityReduceTransparency
                    ? 2.5
                    : 0
            )
            .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
            .accessibilityHidden(navigationCoordinator.isUnifiedSearchPresented)

            if navigationCoordinator.isUnifiedSearchPresented {
                UnifiedSearchPresentationView(
                    pluginHost: pluginHost,
                    launchAtLoginController: launchAtLoginController,
                    appearanceUserDefaults: appearanceUserDefaults,
                    navigationCoordinator: navigationCoordinator
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(1)
            }
        }
        .background {
            SettingsDestinationShortcutButtons(coordinator: navigationCoordinator)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SettingsHistoryNavigationControls(coordinator: navigationCoordinator)
                    .opacity(navigationCoordinator.isUnifiedSearchPresented ? 0 : 1)
                    .allowsHitTesting(!navigationCoordinator.isUnifiedSearchPresented)
                .accessibilityHidden(navigationCoordinator.isUnifiedSearchPresented)
            }
        }
        .id(runtimeLocale.revision)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(\.layoutDirection, layoutDirection)
        .animation(.easeOut(duration: 0.14), value: navigationCoordinator.isUnifiedSearchPresented)
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
            pluginSubpageShortcutButton(key: .upArrow, direction: .previous)
            pluginSubpageShortcutButton(key: .downArrow, direction: .next)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .disabled(coordinator.isUnifiedSearchPresented)
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

    private func pluginSubpageShortcutButton(
        key: KeyEquivalent,
        direction: PluginSubpageMoveDirection
    ) -> some View {
        Button("") {
            coordinator.movePluginSubpage(direction)
        }
        .keyboardShortcut(key, modifiers: [.control, .command])
        .focusable(false)
    }
}

struct SettingsHistoryNavigationControls: View {
    @ObservedObject var coordinator: SettingsNavigationCoordinator

    var body: some View {
        ControlGroup {
            Button {
                coordinator.goBack()
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoBack)
            .help(backTitle)

            Button {
                coordinator.goForward()
            } label: {
                Label(forwardTitle, systemImage: "chevron.forward")
                    .labelStyle(.iconOnly)
            }
            .disabled(!coordinator.canGoForward)
            .help(forwardTitle)
        }
        .controlGroupStyle(.navigation)
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
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var menuBarPanelThemeStore: MenuBarPanelThemeStore
    private let appearanceUserDefaults: UserDefaults
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearancePreferenceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var languagePreferenceRawValue = AppLanguagePreference.system.rawValue
    @AppStorage(MenuBarClickBehaviorPreference.userDefaultsKey) private var clickBehaviorRawValue = MenuBarClickBehaviorPreference.standard.rawValue
    @State private var activeSearchTarget: GeneralSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController,
        menuBarPanelThemeStore: MenuBarPanelThemeStore = .shared,
        appearanceUserDefaults: UserDefaults
    ) {
        self.pluginHost = pluginHost
        self.navigationCoordinator = navigationCoordinator
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        self.menuBarPanelThemeStore = menuBarPanelThemeStore
        self.appearanceUserDefaults = appearanceUserDefaults
        _appearancePreferenceRawValue = AppStorage(
            wrappedValue: AppAppearancePreference.system.rawValue,
            AppAppearancePreference.userDefaultsKey,
            store: appearanceUserDefaults
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsGroupedFormLayout(widthPolicy: .general) { widths in
                Section {
                    LaunchAtLoginSettingsRow(controller: launchAtLoginController)
                        .generalSettingsSearchAnchor(
                            target: .launchAtLogin,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.startup", defaultValue: "启动"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppearanceSettingsRow(selection: appearancePreferenceBinding)
                        .generalSettingsSearchAnchor(
                            target: .appearance,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    MenuBarPanelThemeSettingsRow(
                        themeStore: menuBarPanelThemeStore,
                        appearancePreference: appearancePreferenceBinding.wrappedValue
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    LanguageSettingsRow(selection: languagePreferenceBinding)
                        .generalSettingsSearchAnchor(
                            target: .language,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.appearance", defaultValue: "外观"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    MenuBarIconSettingsView(
                        iconSettings: menuBarIconSettings,
                        gallery: menuBarIconGallery
                    )
                    .generalSettingsSearchAnchor(
                        target: .menuBarIcon,
                        activeTarget: activeSearchTarget
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                    MenuBarClickBehaviorSettingsRow(selection: clickBehaviorBinding)
                        .generalSettingsSearchAnchor(
                            target: .menuBarClickBehavior,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("general.section.menuBarIcon", defaultValue: "状态栏图标"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    AppShortcutSettingsRows(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .appShortcuts,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"),
                        layoutWidth: widths.readableContent
                    )
                }
                Section {
                    PreferencesBackupSettingsRow(pluginHost: pluginHost)
                        .generalSettingsSearchAnchor(
                            target: .preferencesBackup,
                            activeTarget: activeSearchTarget
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.preferencesBackup(
                            "general.section.preferencesBackup",
                            defaultValue: "偏好设置备份"
                        ),
                        layoutWidth: widths.readableContent
                    )
                }
            }
            .onAppear {
                applySearchRevealRequest(
                    navigationCoordinator.searchRevealRequest,
                    proxy: proxy
                )
            }
            .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                applySearchRevealRequest(request, proxy: proxy)
            }
            .onDisappear {
                clearSearchTargetTask?.cancel()
                clearSearchTargetTask = nil
                if let activeSearchTarget {
                    navigationCoordinator.clearSearchRevealRequest(
                        matching: .general(activeSearchTarget)
                    )
                }
                activeSearchTarget = nil
            }
        }
    }

    private var appearancePreferenceBinding: Binding<AppAppearancePreference> {
        Binding {
            AppAppearancePreference(rawValue: appearancePreferenceRawValue) ?? .system
        } set: { preference in
            preference.storeAndApply(in: appearanceUserDefaults)
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

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .general(target) = request.target
        else {
            return
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }

        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
    }
}

private struct GeneralSettingsSearchAnchorModifier: ViewModifier {
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    let target: GeneralSettingsSearchTarget
    let activeTarget: GeneralSettingsSearchTarget?

    func body(content: Content) -> some View {
        content
            .id(target.scrollID)
            .accessibilityFocused($isAccessibilityFocused)
            .overlay {
                if activeTarget == target {
                    RoundedRectangle(
                        cornerRadius: PluginSettingsTheme.Radius.card,
                        style: .continuous
                    )
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {
                focusIfNeeded(activeTarget)
            }
            .onChange(of: activeTarget) { _, newValue in
                focusIfNeeded(newValue)
            }
    }

    private func focusIfNeeded(_ activeTarget: GeneralSettingsSearchTarget?) {
        guard activeTarget == target else {
            return
        }

        isAccessibilityFocused = true
    }
}

private extension View {
    func generalSettingsSearchAnchor(
        target: GeneralSettingsSearchTarget,
        activeTarget: GeneralSettingsSearchTarget?
    ) -> some View {
        modifier(
            GeneralSettingsSearchAnchorModifier(
                target: target,
                activeTarget: activeTarget
            )
        )
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
        static let recorderWidth = PluginSettingsTheme.Size.shortcutRecorderWidth
        static let actionButtonSize: CGFloat = 22
        static let controlSpacing = PluginSettingsTheme.Spacing.controlCluster
        static let controlClusterWidth = recorderWidth + controlSpacing + actionButtonSize
        static let summaryMinWidth: CGFloat = 220
    }

    @ObservedObject var pluginHost: PluginHost
    let item: AppShortcutSettingsItem
    @State private var pendingWarning: CommonShortcutBindingWarning?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                appIcon
                summary
                    .frame(minWidth: Layout.summaryMinWidth)
                shortcutControl
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                HStack(spacing: GeneralSettingsCardLayout.headerSpacing) {
                    appIcon
                    summary
                }

                shortcutControl
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: GeneralSettingsCardLayout.minRowHeight, alignment: .leading)
        .padding(.horizontal, GeneralSettingsCardLayout.horizontalPadding)
        .padding(.vertical, GeneralSettingsCardLayout.verticalPadding)
        .alert(item: $pendingWarning) { warning in
            commonShortcutBindingWarningAlert(warning) {
                _ = save(warning.binding)
            }
        }
    }

    private func record(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        if MacToolsReservedShortcutBindings.requiresConflictWarning(for: binding) {
            pendingWarning = CommonShortcutBindingWarning(shortcutID: item.id, binding: binding)
            return .accepted
        }

        return PluginShortcutRecordingResult.from(errorMessage: save(binding))
    }

    private func save(_ binding: ShortcutBinding) -> String? {
        pluginHost.setAppShortcutBindingAndReturnError(binding, for: item.action)
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GeneralSettingsCardLayout.iconCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

            Image(systemName: item.systemImage)
                .font(PluginSettingsTheme.Typography.pageDescription.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: GeneralSettingsCardLayout.iconSize, height: GeneralSettingsCardLayout.iconSize)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(item.errorMessage ?? item.description)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(item.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutControl: some View {
        HStack(spacing: Layout.controlSpacing) {
            PluginShortcutRecorder(
                title: item.title,
                displayText: item.bindingText,
                minWidth: Layout.recorderWidth,
                onRecord: { binding in
                    record(binding)
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
                    .frame(width: Layout.actionButtonSize, height: Layout.actionButtonSize)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Layout.controlClusterWidth, alignment: .trailing)
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
    private enum Layout {
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarIdealWidth: CGFloat = 220
        static let sidebarMaxWidth: CGFloat = 280
        static let detailMinWidth: CGFloat = 560
    }

    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @ObservedObject var uninstallConfirmationSession: PluginUninstallConfirmationSession
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void
    let orderedPanes: [FeatureSettingsPane]

    var body: some View {
        HSplitView {
            FeatureSettingsSidebar(
                configurationItems: pluginHost.pluginSettingsItems,
                orderedPanes: orderedPanes,
                selection: selectionBinding,
                onSearch: {
                    navigationCoordinator.presentUnifiedSearch(origin: .pluginSidebar)
                }
            )
            .frame(
                minWidth: Layout.sidebarMinWidth,
                idealWidth: Layout.sidebarIdealWidth,
                maxWidth: Layout.sidebarMaxWidth
            )

            FeatureSettingsDetailPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                selectedPane: selectedPane,
                uninstallConfirmationSession: uninstallConfirmationSession,
                showDashboard: showDashboard,
                showFeaturePanel: showFeaturePanel
            )
            .frame(
                minWidth: Layout.detailMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
        .onChange(of: pluginHost.pluginSettingsItems.map(\.id)) {
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
    let configurationItems: [PluginSettingsPageItem]
    let orderedPanes: [FeatureSettingsPane]
    @Binding var selection: FeatureSettingsPane
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchLauncher

            ScrollViewReader { proxy in
                List(selection: optionalSelectionBinding) {
                    Section {
                        ForEach(primaryPanes, id: \.self) { pane in
                            sidebarRow(for: pane)
                        }
                    } header: {
                        Text(AppL10n.settings(
                            "plugins.sidebar.pluginsSection",
                            defaultValue: "插件"
                        ))
                        .accessibilityHidden(true)
                    }

                    Section {
                        if configurationPanes.isEmpty {
                            Text(emptyConfigurationsText)
                                .font(PluginSettingsTheme.Typography.secondaryLabel)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        } else {
                            ForEach(configurationPanes, id: \.self) { pane in
                                sidebarRow(for: pane)
                            }
                        }
                    } header: {
                        Text(AppL10n.settings(
                            "plugins.sidebar.configurationSection",
                            defaultValue: "插件设置"
                        ))
                        .accessibilityHidden(true)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selection) {
                    withAnimation {
                        proxy.scrollTo(selection)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppL10n.settings(
                    "plugins.sidebar.accessibilityLabel",
                    defaultValue: "插件导航"
                ))
                .accessibilityHint(configurationPanes.isEmpty ? emptyConfigurationsText : "")
            }
        }
        .background {
            SettingsSidebarBackground()
        }
    }

    private var emptyConfigurationsText: String {
        AppL10n.settings(
            "plugins.sidebar.emptyConfigurations",
            defaultValue: "暂无可设置插件"
        )
    }

    private var primaryPanes: [FeatureSettingsPane] {
        orderedPanes.filter {
            guard case .configuration = $0 else {
                return true
            }
            return false
        }
    }

    private var configurationPanes: [FeatureSettingsPane] {
        orderedPanes.filter {
            if case .configuration = $0 {
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private func sidebarRow(for pane: FeatureSettingsPane) -> some View {
        switch pane {
        case .dashboardLayout:
            FeatureSettingsSidebarRow(
                title: AppL10n.settings("plugins.sidebar.dashboard", defaultValue: "仪表盘"),
                systemImage: "square.grid.2x2",
                iconTint: .blue
            )
            .tag(pane)
            .id(pane)
        case .featurePanelLayout:
            FeatureSettingsSidebarRow(
                title: AppL10n.settings("plugins.sidebar.featurePanel", defaultValue: "功能面板"),
                systemImage: "switch.2",
                iconTint: .purple
            )
            .tag(pane)
            .id(pane)
        case .marketplace:
            FeatureSettingsSidebarRow(
                title: AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "市场"),
                systemImage: "shippingbox",
                iconTint: .blue
            )
            .tag(pane)
            .id(pane)
        case let .configuration(pluginID):
            if let item = configurationItems.first(where: { $0.id == pluginID }) {
                FeatureSettingsSidebarRow(
                    title: item.title,
                    systemImage: item.iconName,
                    iconTint: item.iconTint
                )
                .tag(pane)
                .id(pane)
            }
        }
    }

    private var searchLauncher: some View {
        Button(action: onSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                Text(
                    AppL10n.search(
                        "search.title",
                        defaultValue: "搜索 MacTools"
                    )
                )
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 4)

                Text("⌘K")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .help(
            AppL10n.search(
                "search.prompt",
                defaultValue: "搜索插件、设置和命令"
            )
        )
        .accessibilityLabel(
            AppL10n.search(
                "search.title",
                defaultValue: "搜索 MacTools"
            )
        )
        .accessibilityHint(
            AppL10n.search(
                "search.prompt",
                defaultValue: "搜索插件、设置和命令"
            )
        )
        .accessibilityIdentifier("mactools.unified-search.launcher")
    }

    private var optionalSelectionBinding: Binding<FeatureSettingsPane?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard let newSelection else {
                    return
                }
                selection = newSelection
            }
        )
    }
}

private struct SettingsSidebarBackground: View {
    private enum Layout {
        /// Aqua's sidebar material is intentionally gray. Let some of the
        /// semantic window surface show through while preserving its depth.
        static let lightMaterialWashOpacity = 0.45
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SettingsStyle.contentBackground

            SettingsSidebarMaterialBackground()

            if colorScheme == .light {
                SettingsStyle.contentBackground
                    .opacity(Layout.lightMaterialWashOpacity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SettingsSidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        // Keep the semantic sidebar material, but sample the app-owned settings
        // surface so a fixed App appearance cannot pick up the opposite Desktop tone.
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
    }
}

private struct FeatureSettingsSidebarRow: View {
    private enum Layout {
        static let iconWidth: CGFloat = 14
    }

    let title: String
    let systemImage: String
    let iconTint: Color

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(iconTint)
                .frame(width: Layout.iconWidth)
        }
        .font(.body)
        .focusable(false)
        .help(title)
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
                navigationCoordinator: navigationCoordinator,
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
                configurationPluginIDs: Set(pluginHost.pluginSettingsItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginSettings(pluginID:),
                onOpenMarketplace: pluginHost.presentPluginMarketplace,
                onUninstall: { pluginID in
                    try pluginHost.uninstallDynamicPlugin(pluginID: pluginID)
                }
            )
        case .featurePanelLayout:
            SurfaceLayoutSettingsView(
                navigationCoordinator: navigationCoordinator,
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
                configurationPluginIDs: Set(pluginHost.pluginSettingsItems.map(\.pluginID)),
                uninstallConfirmationSession: uninstallConfirmationSession,
                onOpenSettings: pluginHost.presentPluginSettings(pluginID:),
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
            PluginSettingsDetailPane(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                item: configurationItem(for: pluginID)
            )
        }
    }

    private func configurationItem(for pluginID: String) -> PluginSettingsPageItem? {
        pluginHost.pluginSettingsItems.first { $0.id == pluginID }
    }
}

private struct SurfaceLayoutSettingsView: View {
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
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
    @State private var activeSearchTarget: SurfaceSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsGroupedFormPageScaffold(
                header: SettingsPageHeaderConfiguration(
                    title: title,
                    description: description,
                    systemImage: systemImage,
                    iconTint: iconTint
                ),
                headerAccessory: {
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
            ) { widths in
                if uninstallConfirmationSession.isConfirmationPaused {
                    Section {
                        PluginUninstallConfirmationPausedBanner(session: uninstallConfirmationSession)
                            .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                }

                Section {
                    if items.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: systemImage,
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    } else {
                        FeatureManagementTableView(
                            items: items.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            highlightedPluginID: highlightedPluginID(in: items),
                            onMove: onMove,
                            onSetVisible: onSetVisible,
                            onOpenSettings: onOpenSettings,
                            onOpenMarketplace: onOpenMarketplace,
                            onRequestUninstall: requestUninstall
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: items.count))
                        .overlay(alignment: .topLeading) {
                            SurfaceLayoutSearchAnchors(
                                surface: surface,
                                items: items,
                                isHidden: false
                            )
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if !hiddenItems.isEmpty {
                    Section {
                        FeatureManagementTableView(
                            items: hiddenItems.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            isReorderEnabled: false,
                            highlightedPluginID: highlightedPluginID(in: hiddenItems),
                            onSetVisible: onSetVisible,
                            onOpenSettings: onOpenSettings,
                            onOpenMarketplace: onOpenMarketplace,
                            onRequestUninstall: requestUninstall
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: hiddenItems.count))
                        .overlay(alignment: .topLeading) {
                            SurfaceLayoutSearchAnchors(
                                surface: surface,
                                items: hiddenItems,
                                isHidden: true
                            )
                        }
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        SettingsGroupedFormSectionHeader(
                            title: hiddenSectionTitle,
                            systemImage: "eye.slash",
                            layoutWidth: widths.readableContent
                        )
                    }
                }
            }
            .onAppear {
                applySearchRevealRequest(
                    navigationCoordinator.searchRevealRequest,
                    proxy: proxy
                )
            }
            .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                applySearchRevealRequest(request, proxy: proxy)
            }
        }
        .onDisappear {
            clearSearchTargetTask?.cancel()
            clearSearchTargetTask = nil
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .surface(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
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

    private func highlightedPluginID(
        in candidates: [PluginSurfaceLayoutItem]
    ) -> String? {
        guard
            let pluginID = activeSearchTarget?.pluginID,
            candidates.contains(where: { $0.id == pluginID })
        else {
            return nil
        }

        return pluginID
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        proxy: ScrollViewProxy
    ) {
        guard
            let request,
            case let .surface(target) = request.target,
            target.surface == surface
        else {
            return
        }

        let isHidden: Bool
        if items.contains(where: { $0.id == target.pluginID }) {
            isHidden = false
        } else if hiddenItems.contains(where: { $0.id == target.pluginID }) {
            isHidden = true
        } else {
            navigationCoordinator.clearSearchRevealRequest(request)
            return
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID(isHidden: isHidden), anchor: .center)
            }
        }

        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
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

private struct SurfaceLayoutSearchAnchors: View {
    let surface: PluginDisplaySurface
    let items: [PluginSurfaceLayoutItem]
    let isHidden: Bool

    var body: some View {
        VStack(spacing: FeatureManagementTableView.rowSpacing) {
            ForEach(items) { item in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: FeatureManagementTableView.rowHeight)
                    .id(
                        SurfaceSettingsSearchTarget(
                            surface: surface,
                            pluginID: item.id
                        )
                        .scrollID(isHidden: isHidden)
                    )
            }
        }
        .padding(.top, FeatureManagementTableView.verticalContentInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PluginSettingsDetailPane: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let item: PluginSettingsPageItem?
    @State private var activeSearchTarget: PluginSettingsSearchTarget?
    @State private var clearSearchTargetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let item {
                ScrollViewReader { proxy in
                    pageContent(item)
                        .environment(\.pluginSettingsSearchTarget, activeSearchTarget)
                        .onAppear {
                            applySearchRevealRequest(
                                navigationCoordinator.searchRevealRequest,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
                        .onChange(of: navigationCoordinator.searchRevealRequest) { _, request in
                            applySearchRevealRequest(
                                request,
                                pluginID: item.pluginID,
                                proxy: proxy
                            )
                        }
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
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            clearSearchTargetTask?.cancel()
            clearSearchTargetTask = nil
            if let activeSearchTarget {
                navigationCoordinator.clearSearchRevealRequest(
                    matching: .plugin(activeSearchTarget)
                )
            }
            activeSearchTarget = nil
        }
    }

    @ViewBuilder
    private func pageContent(_ item: PluginSettingsPageItem) -> some View {
        Group {
            switch item.layout {
            case .form:
                PluginFormPage(pluginHost: pluginHost, item: item)
            case .workspace:
                PluginWorkspacePage(pluginHost: pluginHost, item: item)
            }
        }
        .onAppear {
            pluginHost.setPluginSettingsPage(item.pluginID, visible: true)
        }
        .onDisappear {
            pluginHost.setPluginSettingsPage(item.pluginID, visible: false)
        }
    }

    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String,
        proxy: ScrollViewProxy
    ) {
        guard
            let target = applySearchRevealRequest(request, pluginID: pluginID)
        else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target.scrollID, anchor: .center)
            }
        }
    }

    @discardableResult
    private func applySearchRevealRequest(
        _ request: SettingsSearchRevealRequest?,
        pluginID: String
    ) -> PluginSettingsSearchTarget? {
        guard
            let request,
            case let .plugin(target) = request.target,
            target.pluginID == pluginID
        else {
            return nil
        }

        clearSearchTargetTask?.cancel()
        activeSearchTarget = target
        clearSearchTargetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            activeSearchTarget = nil
            navigationCoordinator.clearSearchRevealRequest(request)
        }
        return target
    }
}

private struct PluginFormPage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsGroupedFormPageScaffold(header: item.headerConfiguration) { widths in
            if !item.permissionCards.isEmpty {
                Section {
                    ForEach(item.permissionCards) { card in
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
                        .pluginSettingsSearchAnchor(
                            pluginID: card.pluginID,
                            entryID: card.id
                        )
                        .settingsGroupedFormRowWidth(widths.sectionLayout)
                    }
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.permissions",
                            defaultValue: "权限"
                        ),
                        systemImage: "lock.shield",
                        layoutWidth: widths.readableContent
                    )
                }
            }

            ForEach(item.sections.filter(\.isVisible)) { section in
                PluginFormSection(
                    pluginHost: pluginHost,
                    pluginID: item.pluginID,
                    section: section,
                    shortcutItems: item.shortcutItems,
                    layoutWidths: widths
                )
            }

            if !item.remainingShortcutItems.isEmpty {
                Section {
                    PluginShortcutRowsContent(
                        pluginHost: pluginHost,
                        items: item.remainingShortcutItems
                    )
                    .settingsGroupedFormRowWidth(widths.sectionLayout)
                } header: {
                    SettingsGroupedFormSectionHeader(
                        title: AppL10n.settings(
                            "plugins.configuration.section.shortcuts",
                            defaultValue: "快捷键"
                        ),
                        systemImage: "command",
                        layoutWidth: widths.readableContent
                    )
                }
            }
        }
    }
}

private extension PluginSettingsPageItem {
    var headerConfiguration: SettingsPageHeaderConfiguration {
        SettingsPageHeaderConfiguration(
            title: title,
            description: description,
            systemImage: iconName,
            iconTint: iconTint
        )
    }
}

private struct PluginFormSection: View {
    @ObservedObject var pluginHost: PluginHost
    let pluginID: String
    let section: PluginSettingsSection
    let shortcutItems: [ShortcutSettingsItem]
    let layoutWidths: SettingsGroupedFormWidths

    var body: some View {
        Section {
            switch section.content {
            case let .rows(rows):
                ForEach(rows.filter(\.isVisible)) { row in
                    PluginSettingsRowView(
                        pluginID: pluginID,
                        row: row,
                        onAction: { action in
                            pluginHost.performSettingsAction(
                                pluginID: pluginID,
                                action: action
                            )
                        }
                    )
                    .pluginSettingsSearchAnchor(
                        pluginID: pluginID,
                        entryID: row.id
                    )
                    .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
                }
            case let .shortcutGroup(groupID):
                PluginShortcutRowsContent(
                    pluginHost: pluginHost,
                    items: shortcutItems.filter { $0.settingsGroupID == groupID }
                )
                .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
            case .custom:
                customContent
            }
        } header: {
            sectionHeader
        } footer: {
            if let footer = section.footer {
                Text(footer)
                    .frame(
                        width: layoutWidths.sectionLayout,
                        alignment: .leading
                    )
            }
        }
    }

    @ViewBuilder
    private var customContent: some View {
        let content = pluginHost.pluginSettingsContentViewItem(
            for: pluginID,
            sectionID: section.id
        ).content
            .settingsGroupedFormRowWidth(layoutWidths.sectionLayout)
        switch section.presentation {
        case .standard:
            content
        case .edgeToEdge:
            content
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if section.title != nil || section.headerAccessory != nil {
            SettingsGroupedFormSectionHeader(
                title: section.title,
                systemImage: section.systemImage,
                layoutWidth: layoutWidths.readableContent
            ) {
                if section.headerAccessory != nil {
                    pluginHost.pluginSettingsHeaderAccessoryViewItem(
                        for: pluginID,
                        sectionID: section.id
                    ).content
                }
            }
        }
    }
}

private struct PluginWorkspacePage: View {
    @ObservedObject var pluginHost: PluginHost
    let item: PluginSettingsPageItem

    var body: some View {
        SettingsPageScaffold(header: item.headerConfiguration) {
            switch item.workspaceScrolling {
            case .host:
                ScrollView {
                    workspaceContent
                }
            case .selfManaged:
                workspaceContent
            }
        }
    }

    private var workspaceContent: some View {
        pluginHost.pluginSettingsContentViewItem(for: item.pluginID).content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PluginSettingsRowView: View {
    let pluginID: String
    let row: PluginSettingsRow
    let onAction: (PluginSettingsAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            HStack(alignment: .center, spacing: 0) {
                HStack(
                    alignment: .center,
                    spacing: PluginSettingsTheme.Spacing.rowContentControl
                ) {
                    if let systemImage = row.systemImage {
                        Image(systemName: systemImage)
                            .pluginSettingsRowIconStyle(.secondary)
                    }

                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(row.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)

                        if let description = row.description {
                            Text(description)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error = row.error {
                Text(error)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help = row.help {
                Text(help)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!row.isEnabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        switch row.control {
        case let .toggle(isOn):
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { onAction(.setBoolean(controlID: row.id, value: $0)) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        case let .picker(selectionID, options, style):
            PluginSettingsPickerControl(
                selectionID: selectionID,
                options: options,
                style: style,
                onSelect: {
                    onAction(.setSelection(controlID: row.id, optionID: $0))
                }
            )
        case let .slider(value, range, step, valueFormat):
            PluginSettingsSliderControl(
                controlID: row.id,
                value: value,
                range: range,
                step: step,
                valueFormat: valueFormat,
                onAction: onAction
            )
        case let .textField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: false,
                onAction: onAction
            )
        case let .secureField(value, prompt, isRequired):
            PluginSettingsTextControl(
                controlID: row.id,
                value: value,
                prompt: prompt,
                isRequired: isRequired,
                isSecure: true,
                onAction: onAction
            )
        case let .action(title, role):
            PluginSettingsActionButton(title: title, role: role) {
                onAction(.invoke(controlID: row.id))
            }
        case let .status(text, systemImage, tone, actionTitle):
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(text, systemImage: systemImage)
                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                    .foregroundStyle(statusColor(for: tone))
                    .lineLimit(1)

                if let actionTitle {
                    Button(actionTitle) {
                        onAction(.invoke(controlID: row.id))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PluginSettingsPickerControl: View {
    let selectionID: String
    let options: [PluginSettingsOption]
    let style: PluginSettingsPickerStyle
    let onSelect: (String) -> Void

    var body: some View {
        switch style {
        case .automatic:
            picker
        case .menu:
            picker.pickerStyle(.menu)
        case .segmented:
            picker.pickerStyle(.segmented)
        case .radioGroup:
            picker.pickerStyle(.radioGroup)
        }
    }

    private var picker: some View {
        Picker(
            "",
            selection: Binding(
                get: { selectionID },
                set: { selection in onSelect(selection) }
            )
        ) {
            ForEach(options) { option in
                Text(option.title).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, idealWidth: 180, maxWidth: 240)
    }
}

private struct PluginSettingsSliderControl: View {
    let controlID: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let valueFormat: PluginSettingsSliderValueFormat?
    let onAction: (PluginSettingsAction) -> Void
    @State private var currentValue: Double

    init(
        controlID: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double?,
        valueFormat: PluginSettingsSliderValueFormat?,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.range = range
        self.step = step
        self.valueFormat = valueFormat
        self.onAction = onAction
        _currentValue = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            PluginSettingsSlider(
                value: $currentValue,
                in: range,
                step: step,
                onEditingChanged: editingChanged
            )

            if let valueFormat {
                Text(valueFormat.text(for: currentValue))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .onChange(of: currentValue) { _, value in
            onAction(.setNumber(controlID: controlID, value: value, phase: .changed))
        }
        .onChange(of: value) { _, value in
            if currentValue != value {
                currentValue = value
            }
        }
    }

    private func editingChanged(_ isEditing: Bool) {
        if !isEditing {
            onAction(.setNumber(controlID: controlID, value: currentValue, phase: .committed))
        }
    }
}

private struct PluginSettingsTextControl: View {
    let controlID: String
    let value: String
    let prompt: String?
    let isRequired: Bool
    let isSecure: Bool
    let onAction: (PluginSettingsAction) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        controlID: String,
        value: String,
        prompt: String?,
        isRequired: Bool,
        isSecure: Bool,
        onAction: @escaping (PluginSettingsAction) -> Void
    ) {
        self.controlID = controlID
        self.value = value
        self.prompt = prompt
        self.isRequired = isRequired
        self.isSecure = isSecure
        self.onAction = onAction
        _text = State(initialValue: value)
    }

    var body: some View {
        Group {
            if isSecure {
                SecureField(prompt ?? "", text: $text)
            } else {
                TextField(prompt ?? "", text: $text)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
        .focused($isFocused)
        .onChange(of: text) { _, value in
            onAction(.setText(controlID: controlID, value: value, phase: .changed))
        }
        .onChange(of: value) { _, value in
            if text != value {
                text = value
            }
        }
        .onChange(of: isFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commit()
            }
        }
        .onSubmit(commit)
    }

    private func commit() {
        guard !isRequired || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onAction(.setText(controlID: controlID, value: text, phase: .committed))
    }
}

private struct PluginSettingsActionButton: View {
    let title: String
    let role: PluginSettingsActionRole
    let action: () -> Void

    var body: some View {
        switch role {
        case .normal:
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .prominent:
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .destructive:
            Button(title, role: .destructive, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct PluginShortcutRowsContent: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [ShortcutSettingsItem]

    var body: some View {
        if groupedItems.isEmpty {
            ShortcutSettingsRowsView(pluginHost: pluginHost, items: items)
        } else {
            GroupedShortcutSettingsRowsView(pluginHost: pluginHost, groups: groupedItems)
        }
    }

    private var groupedItems: [ShortcutSettingsGroup] {
        guard !items.isEmpty, items.allSatisfy({ $0.settingsGroupID != nil }) else {
            return []
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]
        for item in items {
            guard let groupID = item.settingsGroupID else { continue }
            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(item)
        }

        return groupOrder.compactMap { groupID in
            guard let groupItems = groups[groupID], let first = groupItems.first else {
                return nil
            }
            return ShortcutSettingsGroup(
                id: groupID,
                title: first.settingsGroupTitle ?? first.title,
                description: first.settingsGroupDescription ?? first.description,
                items: groupItems
            )
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
                .font(PluginSettingsTheme.Typography.pageTitle)
                .padding(.top, 8)

            Text(AppL10n.settingsFormat("about.versionFormat", defaultValue: "版本 %@", AppMetadata.versionDescription))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            AboutUpdateCard(viewModel: updateViewModel)
                .padding(.top, 28)
                .frame(maxWidth: 420)

            Text(AppMetadata.aboutDescription)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 28)

            VStack(spacing: 0) {
                Link(AppMetadata.repositoryDisplayName, destination: AppMetadata.repositoryURL)
                    .font(PluginSettingsTheme.Typography.rowTitle)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .background(Color(nsColor: .windowBackgroundColor))
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
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
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
                .background(PluginSettingsTheme.Palette.recessedControlBackground)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
