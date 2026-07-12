import SwiftUI
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
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var menuBarIconSettings: MenuBarIconSettings
    @ObservedObject var menuBarIconGallery: MenuBarIconGalleryLibrary
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    var body: some View {
        // Recreate native AppKit-backed controls when the shared locale changes.
        let _ = runtimeLocale.revision

        return TabView(selection: $pluginHost.selectedSettingsDestination) {
            GeneralSettingsView(
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
                showDashboard: showDashboard,
                showFeaturePanel: showFeaturePanel
            )
                .tag(SettingsDestination.pluginConfiguration)
                .tabItem {
                    Label(AppL10n.settings("tab.plugins", defaultValue: "插件"), systemImage: "slider.horizontal.3")
                }

            AboutSettingsView(appUpdater: appUpdater)
                .tag(SettingsDestination.about)
                .tabItem {
                    Label(AppL10n.settings("tab.about", defaultValue: "关于"), systemImage: "info.circle")
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
                    .lineLimit(1)
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
            .frame(width: 150, alignment: .trailing)
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
                showDashboard: showDashboard,
                showFeaturePanel: showFeaturePanel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsStyle.windowBackground)
    }

    private var selectionBinding: Binding<FeatureSettingsPane> {
        Binding {
            pluginHost.selectedFeatureSettingsPane
        } set: { selection in
            pluginHost.selectFeatureSettingsPane(selection)
        }
    }
}

private struct FeatureSettingsSidebar: View {
    let configurationItems: [PluginConfigurationItem]
    @Binding var selection: FeatureSettingsPane

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                FeatureSettingsSidebarSectionTitle(AppL10n.settings(
                    "plugins.sidebar.layoutSection",
                    defaultValue: "菜单栏布局"
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

                FeatureSettingsSidebarSectionTitle(AppL10n.settings(
                    "plugins.sidebar.pluginsSection",
                    defaultValue: "插件"
                ))
                    .padding(.top, 16)

                FeatureSettingsSidebarRow(
                    title: AppL10n.settings("plugins.sidebar.installed", defaultValue: "已安装"),
                    systemImage: "checkmark.circle",
                    iconTint: .green,
                    isSelected: selection == .installed
                ) {
                    selection = .installed
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
                            isSelected: selection == .configuration(item.id),
                            isEnabled: item.isGloballyEnabled
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
    var isEnabled = true
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
                .opacity(isEnabled ? 1 : 0.6)

                Spacer(minLength: 0)

                if !isEnabled {
                    Image(systemName: "pause.circle")
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(.tertiary)
                        .help(AppL10n.plugins(
                            "plugin.management.disabled",
                            defaultValue: "插件已停用"
                        ))
                        .accessibilityLabel(AppL10n.plugins(
                            "plugin.management.disabled",
                            defaultValue: "插件已停用"
                        ))
                }
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
    let showDashboard: () -> Void
    let showFeaturePanel: () -> Void

    var body: some View {
        switch pluginHost.selectedFeatureSettingsPane {
        case .dashboardLayout:
            SurfaceLayoutSettingsView(
                surface: .dashboard,
                title: AppL10n.settings("plugins.dashboard.title", defaultValue: "仪表盘"),
                description: AppL10n.settings(
                    "plugins.dashboard.description",
                    defaultValue: "拖拽调整已启用仪表盘组件的排列顺序。"
                ),
                systemImage: "square.grid.2x2",
                iconTint: .blue,
                items: pluginHost.dashboardLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.dashboard.open", defaultValue: "打开仪表盘"),
                emptyTitle: AppL10n.settings("plugins.dashboard.empty.title", defaultValue: "暂无仪表盘组件"),
                emptyDescription: AppL10n.settings(
                    "plugins.dashboard.empty.description",
                    defaultValue: "已启用且支持仪表盘的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .dashboard)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .dashboard) },
                onOpenPanel: showDashboard,
                configurationPluginIDs: Set(pluginHost.pluginConfigurationItems.map(\.pluginID)),
                onOpenSettings: pluginHost.presentPluginConfiguration(pluginID:),
                onEnablementChange: { pluginID, isEnabled in
                    pluginHost.setPluginGloballyEnabled(isEnabled, pluginID: pluginID)
                }
            )
        case .featurePanelLayout:
            SurfaceLayoutSettingsView(
                surface: .featurePanel,
                title: AppL10n.settings("plugins.featurePanel.title", defaultValue: "功能面板"),
                description: AppL10n.settings(
                    "plugins.featurePanel.description",
                    defaultValue: "拖拽调整已启用功能面板操作的排列顺序。"
                ),
                systemImage: "switch.2",
                iconTint: .purple,
                items: pluginHost.featurePanelLayoutItems,
                openButtonTitle: AppL10n.settings("plugins.featurePanel.open", defaultValue: "打开功能面板"),
                emptyTitle: AppL10n.settings("plugins.featurePanel.empty.title", defaultValue: "暂无功能面板操作"),
                emptyDescription: AppL10n.settings(
                    "plugins.featurePanel.empty.description",
                    defaultValue: "已启用且支持功能面板的插件会显示在这里。"
                ),
                onMove: { pluginID, targetOffset in
                    pluginHost.movePlugin(id: pluginID, toOffset: targetOffset, on: .featurePanel)
                },
                onResetOrder: { pluginHost.resetPluginOrder(on: .featurePanel) },
                onOpenPanel: showFeaturePanel,
                configurationPluginIDs: Set(pluginHost.pluginConfigurationItems.map(\.pluginID)),
                onOpenSettings: pluginHost.presentPluginConfiguration(pluginID:),
                onEnablementChange: { pluginID, isEnabled in
                    pluginHost.setPluginGloballyEnabled(isEnabled, pluginID: pluginID)
                }
            )
        case .installed:
            InstalledFeaturesSettingsView(pluginHost: pluginHost)
        case .marketplace:
            PluginManagementSettingsView(pluginHost: pluginHost)
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

private struct InstalledFeaturesSettingsView: View {
    @ObservedObject var pluginHost: PluginHost
    @State private var searchText: String = ""
    @State private var selectedFilter: PluginCategoryFilter = .all

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsPageHeader(
                    title: AppL10n.settings("plugins.installed.title", defaultValue: "已安装"),
                    description: AppL10n.settings(
                        "plugins.installed.globalDescription",
                        defaultValue: "启用或停用插件；仪表盘和功能面板仅管理显示位置与顺序。"
                    ),
                    systemImage: "checkmark.circle",
                    iconTint: .green
                )

                if !pluginHost.installedPluginItems.isEmpty {
                    PluginFilterBarView(
                        searchText: $searchText,
                        selectedFilter: $selectedFilter,
                        countsByFilter: countsByFilter,
                        searchPrompt: AppL10n.settings("plugins.installed.searchPrompt", defaultValue: "搜索已安装插件")
                    )
                }

                SettingsCardContainer {
                    if pluginHost.installedPluginItems.isEmpty {
                        ContentUnavailableView(
                            AppL10n.settings("plugins.installed.empty.title", defaultValue: "暂无已安装插件"),
                            systemImage: "checkmark.circle",
                            description: Text(AppL10n.settings("plugins.installed.empty.description", defaultValue: "安装插件后，会显示在这里。"))
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else if filteredItems.isEmpty {
                        ContentUnavailableView(
                            AppL10n.settings("plugins.filter.empty.title", defaultValue: "未找到匹配的插件"),
                            systemImage: "magnifyingglass",
                            description: Text(AppL10n.settings("plugins.filter.empty.description", defaultValue: "尝试调整关键字或切换分类。"))
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        FeatureManagementTableView(
                            items: filteredItems.map(FeatureManagementTableItem.init(installedItem:)),
                            mode: .installed,
                            isReorderEnabled: false,
                            onToggleChange: { pluginID, isEnabled in
                                pluginHost.setPluginGloballyEnabled(isEnabled, pluginID: pluginID)
                            }
                        )
                        .frame(height: featureManagementListHeight)
                    }
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SettingsStyle.contentBackground)
    }

    private var filteredItems: [InstalledPluginItem] {
        pluginHost.installedPluginItems.filter {
            PluginListFilter.matches(installedItem: $0, query: searchText, filter: selectedFilter)
        }
    }

    private var countsByFilter: [PluginCategoryFilter: Int] {
        PluginListFilter.countsByFilter(
            installedItems: pluginHost.installedPluginItems,
            query: searchText
        )
    }

    private var featureManagementListHeight: CGFloat {
        FeatureManagementTableView.preferredHeight(for: filteredItems.count)
    }
}

private struct SurfaceLayoutSettingsView: View {
    let surface: PluginDisplaySurface
    let title: String
    let description: String
    let systemImage: String
    let iconTint: Color
    let items: [PluginSurfaceLayoutItem]
    let openButtonTitle: String
    let emptyTitle: String
    let emptyDescription: String
    let onMove: (String, Int) -> Void
    let onResetOrder: () -> Void
    let onOpenPanel: () -> Void
    let configurationPluginIDs: Set<String>
    let onOpenSettings: (String) -> Void
    let onEnablementChange: (String, Bool) -> Void

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
                        .disabled(enabledItems.count < 2)

                    Button(action: onOpenPanel) {
                        Label(openButtonTitle, systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                SettingsCardContainer {
                    if enabledItems.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: systemImage,
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        FeatureManagementTableView(
                            items: enabledItems.map {
                                FeatureManagementTableItem(
                                    surfaceItem: $0,
                                    hasSettings: configurationPluginIDs.contains($0.id)
                                )
                            },
                            mode: .surface(surface),
                            onToggleChange: onEnablementChange,
                            onMove: onMove,
                            onOpenSettings: onOpenSettings
                        )
                        .frame(height: FeatureManagementTableView.preferredHeight(for: enabledItems.count))
                    }
                }

                if !disabledItems.isEmpty {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                        Label(
                            AppL10n.settingsFormat(
                                "plugins.layout.disabledSectionFormat",
                                defaultValue: "已停用插件（%d）",
                                disabledItems.count
                            ),
                            systemImage: "pause.circle"
                        )
                        .font(PluginSettingsTheme.Typography.sectionTitle)
                        .foregroundStyle(.secondary)

                        SettingsCardContainer {
                            FeatureManagementTableView(
                                items: disabledItems.map {
                                    FeatureManagementTableItem(
                                        surfaceItem: $0,
                                        hasSettings: configurationPluginIDs.contains($0.id)
                                    )
                                },
                                mode: .surface(surface),
                                isReorderEnabled: false,
                                onToggleChange: onEnablementChange,
                                onOpenSettings: onOpenSettings
                            )
                            .frame(height: FeatureManagementTableView.preferredHeight(for: disabledItems.count))
                        }
                    }
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SettingsStyle.contentBackground)
    }

    private var enabledItems: [PluginSurfaceLayoutItem] {
        PluginSurfaceLayoutDisplayPolicy.enabledItems(from: items)
    }

    private var disabledItems: [PluginSurfaceLayoutItem] {
        PluginSurfaceLayoutDisplayPolicy.disabledItems(from: items)
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
                        PluginConfigurationHeader(pluginHost: pluginHost, item: item)
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
                            PluginConfigurationHeader(pluginHost: pluginHost, item: item)

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
    @ObservedObject var pluginHost: PluginHost
    let item: PluginConfigurationItem

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            SettingsPageHeader(
                title: item.title,
                description: item.description,
                systemImage: item.iconName,
                iconTint: item.iconTint
            )

            Toggle(
                AppL10n.settings("plugins.configuration.enabled", defaultValue: "已启用"),
                isOn: enabledBinding
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .help(AppL10n.settings(
                "plugins.configuration.enabled",
                defaultValue: "已启用"
            ))
        }
        .padding(.bottom, 2)
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            pluginHost.installedPluginItems.first { $0.id == item.pluginID }?.isGloballyEnabled ?? true
        } set: { isEnabled in
            pluginHost.setPluginGloballyEnabled(isEnabled, pluginID: item.pluginID)
        }
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

    init(appUpdater: AppUpdater) {
        _updateViewModel = StateObject(
            wrappedValue: AboutUpdateViewModel(updater: appUpdater)
        )
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
