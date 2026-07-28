import Foundation
import MacToolsPluginKit

enum MacToolsSearchResultKind: CaseIterable, Hashable {
    case navigation
    case setting
    case command

    var title: String {
        switch self {
        case .navigation:
            return AppL10n.search("search.group.navigation", defaultValue: "导航")
        case .setting:
            return AppL10n.search("search.group.settings", defaultValue: "设置")
        case .command:
            return AppL10n.search("search.group.commands", defaultValue: "命令")
        }
    }

    var actionTitle: String {
        switch self {
        case .navigation:
            return AppL10n.search("search.action.open", defaultValue: "打开")
        case .setting:
            return AppL10n.search("search.action.goTo", defaultValue: "前往")
        case .command:
            return AppL10n.search("search.action.run", defaultValue: "执行")
        }
    }
}

enum MacToolsSearchAction: Hashable {
    case navigate(
        destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    )
    case pluginCommand(pluginID: String, commandID: String)
    case appCommand(AppShortcutAction)
}

struct MacToolsSearchResult: Identifiable, Hashable {
    let id: String
    let kind: MacToolsSearchResultKind
    let title: String
    let subtitle: String
    let detail: String
    let keywords: [String]
    let systemImage: String
    let action: MacToolsSearchAction
    let confirmation: PluginCommandDefinition.Confirmation?
    let suggestionPriority: Int?

    var accessibilityLabel: String {
        [title, subtitle, kind.title].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    fileprivate var normalizedTitle: String {
        Self.normalize(title)
    }

    fileprivate var normalizedSubtitle: String {
        Self.normalize(subtitle)
    }

    fileprivate var normalizedDetail: String {
        Self.normalize(detail)
    }

    fileprivate var normalizedKeywords: String {
        Self.normalize(keywords.joined(separator: " "))
    }

    fileprivate static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MacToolsSearchIndex {
    let items: [MacToolsSearchResult]
    private let indexedItems: [IndexedItem]

    init(items: [MacToolsSearchResult]) {
        self.items = items
        self.indexedItems = items.map(IndexedItem.init)
    }

    func results(matching query: String) -> [MacToolsSearchResult] {
        let normalizedQuery = MacToolsSearchResult.normalize(query)
        guard !normalizedQuery.isEmpty else {
            return items
                .filter { $0.suggestionPriority != nil }
                .sorted(by: suggestionOrder)
        }

        let tokens = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        return indexedItems
            .compactMap { item -> (IndexedItem, Int)? in
                guard tokens.allSatisfy(item.haystack.contains) else {
                    return nil
                }

                return (item, score(item, query: normalizedQuery, tokens: tokens))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }

                if lhs.0.result.kind != rhs.0.result.kind {
                    return kindOrder(lhs.0.result.kind) < kindOrder(rhs.0.result.kind)
                }

                return lhs.0.result.title.localizedStandardCompare(rhs.0.result.title) == .orderedAscending
            }
            .map(\.0.result)
    }

    private func score(
        _ item: IndexedItem,
        query: String,
        tokens: [String]
    ) -> Int {
        var score = 0

        if item.normalizedTitle == query {
            score += 1_000
        } else if item.normalizedTitle.hasPrefix(query) {
            score += 700
        } else if item.normalizedTitle.contains(query) {
            score += 500
        }

        for token in tokens {
            if item.normalizedTitle.contains(token) {
                score += 180
            }
            if item.normalizedSubtitle.contains(token) {
                score += 90
            }
            if item.normalizedDetail.contains(token) {
                score += 50
            }
            if item.normalizedKeywords.contains(token) {
                score += 30
            }
        }

        if item.result.kind == .navigation {
            score += 10
        }

        return score
    }

    private func suggestionOrder(
        _ lhs: MacToolsSearchResult,
        _ rhs: MacToolsSearchResult
    ) -> Bool {
        let lhsPriority = lhs.suggestionPriority ?? .max
        let rhsPriority = rhs.suggestionPriority ?? .max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func kindOrder(_ kind: MacToolsSearchResultKind) -> Int {
        switch kind {
        case .navigation: 0
        case .setting: 1
        case .command: 2
        }
    }

    private struct IndexedItem {
        let result: MacToolsSearchResult
        let normalizedTitle: String
        let normalizedSubtitle: String
        let normalizedDetail: String
        let normalizedKeywords: String
        let haystack: String

        init(result: MacToolsSearchResult) {
            self.result = result
            normalizedTitle = result.normalizedTitle
            normalizedSubtitle = result.normalizedSubtitle
            normalizedDetail = result.normalizedDetail
            normalizedKeywords = result.normalizedKeywords
            haystack = [
                normalizedTitle,
                normalizedSubtitle,
                normalizedDetail,
                normalizedKeywords
            ].joined(separator: " ")
        }
    }
}

enum MacToolsSearchPresentation {
    static let quickSelectionLimit = 9

    static func orderedResults(
        _ results: [MacToolsSearchResult]
    ) -> [MacToolsSearchResult] {
        MacToolsSearchResultKind.allCases.flatMap { kind in
            results.filter { $0.kind == kind }
        }
    }

    static func quickSelectionNumber(
        for resultID: String,
        in results: [MacToolsSearchResult]
    ) -> Int? {
        guard
            let index = results.prefix(quickSelectionLimit)
                .firstIndex(where: { $0.id == resultID })
        else {
            return nil
        }

        return results.distance(from: results.startIndex, to: index) + 1
    }
}

@MainActor
enum MacToolsSearchIndexBuilder {
    static func build(pluginHost: PluginHost) -> MacToolsSearchIndex {
        var items: [MacToolsSearchResult] = [
            navigationResult(
                id: "navigation.general",
                title: AppL10n.settings("tab.general", defaultValue: "通用"),
                subtitle: AppL10n.search("search.subtitle.appSettings", defaultValue: "应用设置"),
                detail: AppL10n.search(
                    "search.detail.general",
                    defaultValue: "外观、语言、菜单栏图标、登录启动和偏好备份。"
                ),
                systemImage: "gearshape",
                destination: .general,
                suggestionPriority: 3
            ),
            navigationResult(
                id: "navigation.dashboard",
                title: AppL10n.settings("plugins.sidebar.dashboard", defaultValue: "仪表盘"),
                subtitle: AppL10n.search("search.subtitle.plugins", defaultValue: "插件"),
                detail: AppL10n.settings(
                    "plugins.dashboard.description",
                    defaultValue: "拖拽调整仪表盘组件的排列顺序。"
                ),
                systemImage: "square.grid.2x2",
                destination: .plugins(.dashboardLayout),
                suggestionPriority: 0
            ),
            navigationResult(
                id: "navigation.feature-panel",
                title: AppL10n.settings("plugins.sidebar.featurePanel", defaultValue: "功能面板"),
                subtitle: AppL10n.search("search.subtitle.plugins", defaultValue: "插件"),
                detail: AppL10n.settings(
                    "plugins.featurePanel.description",
                    defaultValue: "拖拽调整功能面板操作的排列顺序。"
                ),
                systemImage: "switch.2",
                destination: .plugins(.featurePanelLayout),
                suggestionPriority: 1
            ),
            navigationResult(
                id: "navigation.marketplace",
                title: AppL10n.settings("plugins.sidebar.marketplace", defaultValue: "市场"),
                subtitle: AppL10n.search("search.subtitle.plugins", defaultValue: "插件"),
                detail: AppL10n.plugins(
                    "plugin.marketplace.description",
                    defaultValue: "安装、更新和管理 MacTools 插件。"
                ),
                systemImage: "shippingbox",
                destination: .plugins(.marketplace),
                suggestionPriority: 2
            ),
            navigationResult(
                id: "navigation.about",
                title: AppL10n.settings("tab.about", defaultValue: "关于"),
                subtitle: AppL10n.search("search.subtitle.appSettings", defaultValue: "应用设置"),
                detail: AppL10n.search(
                    "search.detail.about",
                    defaultValue: "版本、更新和项目链接。"
                ),
                systemImage: "info.circle",
                destination: .about,
                suggestionPriority: 4
            )
        ]

        items += generalSettingsResults(pluginHost: pluginHost)

        let managementItemsByID = Dictionary(
            uniqueKeysWithValues: pluginHost.pluginManagementItems.map { ($0.id, $0) }
        )
        let configurationItemsByID = Dictionary(
            uniqueKeysWithValues: pluginHost.pluginConfigurationItems.map { ($0.pluginID, $0) }
        )

        items += pluginHost.pluginConfigurationItems.map { item in
            let managementItem = managementItemsByID[item.pluginID]
            return MacToolsSearchResult(
                id: "plugin.\(item.pluginID)",
                kind: .navigation,
                title: item.title,
                subtitle: AppL10n.settings(
                    "plugins.sidebar.configurationSection",
                    defaultValue: "插件设置"
                ),
                detail: item.description,
                keywords: [managementItem?.category, managementItem?.releaseChannel]
                    .compactMap { $0 },
                systemImage: item.iconName,
                action: .navigate(
                    destination: .plugins(.configuration(item.pluginID)),
                    target: nil
                ),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        let surfaceItems = mergedSurfaceItems(pluginHost: pluginHost)
        items += surfaceItems.compactMap { item -> MacToolsSearchResult? in
            guard configurationItemsByID[item.id] == nil else {
                return nil
            }

            let destination: SettingsNavigationDestination
            let surface: PluginDisplaySurface
            let subtitle: String
            if item.capabilities.supportsFeaturePanel {
                surface = .featurePanel
                destination = .plugins(.featurePanelLayout)
                subtitle = AppL10n.settings(
                    "plugins.sidebar.featurePanel",
                    defaultValue: "功能面板"
                )
            } else if item.capabilities.supportsDashboard {
                surface = .dashboard
                destination = .plugins(.dashboardLayout)
                subtitle = AppL10n.settings(
                    "plugins.sidebar.dashboard",
                    defaultValue: "仪表盘"
                )
            } else {
                return nil
            }

            return MacToolsSearchResult(
                id: "plugin.\(item.id)",
                kind: .navigation,
                title: item.title,
                subtitle: subtitle,
                detail: item.description,
                keywords: [item.category, item.releaseChannel].compactMap { $0 },
                systemImage: item.iconName,
                action: .navigate(
                    destination: destination,
                    target: .surface(
                        SurfaceSettingsSearchTarget(
                            surface: surface,
                            pluginID: item.id
                        )
                    )
                ),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        items += pluginHost.pluginConfigurationItems.flatMap { item in
            settingResults(for: item)
        }

        items += pluginHost.pluginSettingsSearchItems.compactMap { providedItem in
            guard let configuration = configurationItemsByID[providedItem.pluginID] else {
                return nil
            }

            let entry = providedItem.entry
            return MacToolsSearchResult(
                id: providedItem.id,
                kind: .setting,
                title: entry.title,
                subtitle: "\(configuration.title) › \(AppL10n.search("search.subtitle.customSetting", defaultValue: "设置"))",
                detail: entry.description,
                keywords: entry.keywords,
                systemImage: entry.systemImage,
                action: .navigate(
                    destination: .plugins(.configuration(providedItem.pluginID)),
                    target: .plugin(
                        PluginSettingsSearchTarget(
                            pluginID: providedItem.pluginID,
                            entryID: entry.id
                        )
                    )
                ),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        items += pluginHost.pluginCommandItems.map { item in
            MacToolsSearchResult(
                id: item.id,
                kind: .command,
                title: item.definition.title,
                subtitle: item.pluginTitle,
                detail: item.definition.description,
                keywords: item.definition.keywords,
                systemImage: item.definition.systemImage,
                action: .pluginCommand(
                    pluginID: item.pluginID,
                    commandID: item.definition.id
                ),
                confirmation: item.definition.confirmation,
                suggestionPriority: nil
            )
        }

        items += AppShortcutAction.allCases.compactMap { action -> MacToolsSearchResult? in
            guard action != .openSettings else {
                return nil
            }

            return MacToolsSearchResult(
                id: "app-command.\(action.rawValue)",
                kind: .command,
                title: action.title,
                subtitle: AppL10n.search("search.subtitle.macTools", defaultValue: "MacTools"),
                detail: action.description,
                keywords: [],
                systemImage: action.systemImage,
                action: .appCommand(action),
                confirmation: nil,
                suggestionPriority: nil
            )
        }

        return MacToolsSearchIndex(items: deduplicated(items))
    }

    private static func navigationResult(
        id: String,
        title: String,
        subtitle: String,
        detail: String,
        systemImage: String,
        destination: SettingsNavigationDestination,
        suggestionPriority: Int
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: .navigation,
            title: title,
            subtitle: subtitle,
            detail: detail,
            keywords: [],
            systemImage: systemImage,
            action: .navigate(destination: destination, target: nil),
            confirmation: nil,
            suggestionPriority: suggestionPriority
        )
    }

    private static func generalSettingsResults(
        pluginHost: PluginHost
    ) -> [MacToolsSearchResult] {
        let shortcutKeywords = pluginHost.appShortcutItems.flatMap { item in
            [item.title, item.description, item.bindingText]
        }

        return [
            generalSettingResult(
                target: .launchAtLogin,
                title: AppL10n.settings("launchAtLogin.title", defaultValue: "开机时启动"),
                detail: AppL10n.settings(
                    "launchAtLogin.description",
                    defaultValue: "登录系统时自动启动 MacTools 并显示在菜单栏。"
                ),
                keywords: [
                    AppL10n.settings("general.section.startup", defaultValue: "启动")
                ],
                systemImage: "power"
            ),
            generalSettingResult(
                target: .appearance,
                title: AppL10n.settings("appearance.title", defaultValue: "应用外观"),
                detail: AppL10n.settings(
                    "appearance.description",
                    defaultValue: "自动跟随系统，也可以固定为深色或浅色。"
                ),
                keywords: AppAppearancePreference.allCases.map(\.title),
                systemImage: "circle.lefthalf.filled"
            ),
            generalSettingResult(
                target: .language,
                title: AppL10n.settings("language.title", defaultValue: "语言"),
                detail: AppL10n.settings(
                    "language.description",
                    defaultValue: "默认跟随系统语言，也可以固定为指定语言。"
                ),
                keywords: AppLanguagePreference.allCases.map(\.pickerTitle),
                systemImage: "globe"
            ),
            generalSettingResult(
                target: .menuBarIcon,
                title: AppL10n.settings("menuBarIcon.title", defaultValue: "菜单栏图标"),
                detail: AppL10n.settings(
                    "menuBarIcon.description",
                    defaultValue: "统一设置浅色和深色菜单栏图标，导入时会保留原图。"
                ),
                keywords: [
                    AppL10n.settings("menuBarIcon.restoreDefault", defaultValue: "恢复默认")
                ],
                systemImage: "menubar.rectangle"
            ),
            generalSettingResult(
                target: .menuBarClickBehavior,
                title: AppL10n.settings("menuBarClick.title", defaultValue: "交换左键与右键功能"),
                detail: AppL10n.settings(
                    "menuBarClick.description",
                    defaultValue: "关闭时左键打开仪表盘、右键功能打开功能面板；开启后互换。"
                ),
                keywords: [
                    AppL10n.settings("general.section.menuBarIcon", defaultValue: "状态栏图标"),
                    AppL10n.settings(
                        "menuBarClick.rightClickShortcutNotice",
                        defaultValue: "可以使用 Option + 左键触发右键功能。"
                    )
                ],
                systemImage: "cursorarrow.click.2"
            ),
            generalSettingResult(
                target: .appShortcuts,
                title: AppL10n.settings("shortcuts.title", defaultValue: "键盘快捷键"),
                detail: AppL10n.settings(
                    "shortcuts.description",
                    defaultValue: "为常用动作配置全局快捷键。编辑后立即生效，必要项不可删除。"
                ),
                keywords: shortcutKeywords,
                systemImage: "command"
            ),
            generalSettingResult(
                target: .preferencesBackup,
                title: AppL10n.preferencesBackup(
                    "preferencesBackup.title",
                    defaultValue: "导出与导入偏好设置"
                ),
                detail: AppL10n.preferencesBackup(
                    "preferencesBackup.description",
                    defaultValue: "包含应用偏好、插件显示顺序、快捷键和支持导出的插件设置；不会包含权限、缓存、凭证或其他私有数据。"
                ),
                keywords: [
                    AppL10n.preferencesBackup(
                        "preferencesBackup.export",
                        defaultValue: "导出偏好设置…"
                    ),
                    AppL10n.preferencesBackup(
                        "preferencesBackup.import",
                        defaultValue: "导入偏好设置…"
                    )
                ],
                systemImage: "externaldrive.badge.checkmark"
            )
        ]
    }

    private static func generalSettingResult(
        target: GeneralSettingsSearchTarget,
        title: String,
        detail: String,
        keywords: [String],
        systemImage: String
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: "general-setting.\(target.rawValue)",
            kind: .setting,
            title: title,
            subtitle: AppL10n.settings("tab.general", defaultValue: "通用"),
            detail: detail,
            keywords: keywords,
            systemImage: systemImage,
            action: .navigate(destination: .general, target: .general(target)),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private static func settingResults(
        for item: PluginConfigurationItem
    ) -> [MacToolsSearchResult] {
        let settings = item.settingsCards.map { card in
            settingResult(
                id: "setting-card.\(card.id)",
                item: item,
                title: card.title,
                detail: card.description,
                keywords: [card.statusText, card.footnote].compactMap { $0 },
                systemImage: card.statusSystemImage,
                entryID: card.id
            )
        }

        let permissions = item.permissionCards.map { card in
            settingResult(
                id: "permission.\(card.id)",
                item: item,
                title: card.title,
                detail: card.description,
                keywords: [
                    AppL10n.settings(
                        "plugins.configuration.section.permissions",
                        defaultValue: "权限"
                    ),
                    card.statusText,
                    card.footnote
                ].compactMap { $0 },
                systemImage: card.iconSystemImage,
                entryID: card.id
            )
        }

        let shortcuts = shortcutSettingResults(for: item)

        return settings + permissions + shortcuts
    }

    private static func shortcutSettingResults(
        for item: PluginConfigurationItem
    ) -> [MacToolsSearchResult] {
        guard item.shortcutItems.allSatisfy({ $0.settingsGroupID != nil }) else {
            return item.shortcutItems.map { shortcut in
                settingResult(
                    id: "shortcut.\(shortcut.id)",
                    item: item,
                    title: shortcut.settingsControlTitle ?? shortcut.title,
                    detail: shortcut.description,
                    keywords: [
                        AppL10n.settings(
                            "plugins.configuration.section.shortcuts",
                            defaultValue: "快捷键"
                        ),
                        shortcut.bindingText
                    ],
                    systemImage: shortcut.settingsControlSystemImage ?? "command",
                    entryID: shortcut.id
                )
            }
        }

        var groupOrder: [String] = []
        var groups: [String: [ShortcutSettingsItem]] = [:]
        for shortcut in item.shortcutItems {
            guard let groupID = shortcut.settingsGroupID else {
                continue
            }

            if groups[groupID] == nil {
                groupOrder.append(groupID)
            }
            groups[groupID, default: []].append(shortcut)
        }

        return groupOrder.compactMap { groupID in
            guard let shortcuts = groups[groupID], let first = shortcuts.first else {
                return nil
            }

            return settingResult(
                id: "shortcut-group.\(item.pluginID).\(groupID)",
                item: item,
                title: first.settingsGroupTitle ?? first.title,
                detail: first.settingsGroupDescription ?? first.description,
                keywords: [
                    AppL10n.settings(
                        "plugins.configuration.section.shortcuts",
                        defaultValue: "快捷键"
                    )
                ] + shortcuts.flatMap {
                    [$0.settingsControlTitle, $0.title, $0.bindingText].compactMap { $0 }
                },
                systemImage: first.settingsControlSystemImage ?? "command",
                entryID: groupID
            )
        }
    }

    private static func settingResult(
        id: String,
        item: PluginConfigurationItem,
        title: String,
        detail: String,
        keywords: [String],
        systemImage: String,
        entryID: String
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: .setting,
            title: title,
            subtitle: item.title,
            detail: detail,
            keywords: keywords,
            systemImage: systemImage,
            action: .navigate(
                destination: .plugins(.configuration(item.pluginID)),
                target: .plugin(
                    PluginSettingsSearchTarget(
                        pluginID: item.pluginID,
                        entryID: entryID
                    )
                )
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private static func mergedSurfaceItems(pluginHost: PluginHost) -> [PluginSurfaceLayoutItem] {
        var seenIDs: Set<String> = []
        return (
            pluginHost.featurePanelLayoutItems
                + pluginHost.featurePanelHiddenLayoutItems
                + pluginHost.dashboardLayoutItems
                + pluginHost.dashboardHiddenLayoutItems
        ).filter { seenIDs.insert($0.id).inserted }
    }

    private static func deduplicated(
        _ items: [MacToolsSearchResult]
    ) -> [MacToolsSearchResult] {
        var seenIDs: Set<String> = []
        return items.filter { seenIDs.insert($0.id).inserted }
    }
}
