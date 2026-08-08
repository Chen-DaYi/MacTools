import AppKit
import Combine
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class MacToolsSearchTests: XCTestCase {
    func testIndexIncludesNavigationDeclarativeSettingsCustomSettingsAndCommands() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin, SurfaceOnlySearchTestPlugin()])
        let appCommand = appHostCommandDefinition(
            id: "app-command.toggle-dashboard",
            action: .appShortcut(.toggleDashboard)
        )
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: host,
            appHostCommandDefinitions: [appCommand]
        )

        XCTAssertTrue(index.items.contains {
            $0.kind == .navigation && $0.title == plugin.metadata.title
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "自动切换"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "辅助功能授权"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "降低亮度"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "快捷键目标"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == "让显示器休眠"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.toggleDashboard.title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openCommandPalette.title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openSettings.title
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-command-palette"
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-settings"
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.appearance" && $0.kind == .setting
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.preferencesBackup" && $0.kind == .setting
        })
    }

    func testCommandResultsCarryCanonicalActionReferences() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == "让显示器休眠"
            }
        )

        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected the shared action executor route")
        }
        XCTAssertEqual(reference.key, ActionKey(providerID: "searchable", actionID: "sleep"))
        XCTAssertNotNil(try? host.actionRegistry.registeredAction(for: reference).get())
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.status,
            .unassigned
        )
    }

    func testMacToolsSearchActionExecutesThroughPresentationRouting() async throws {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == AppShortcutAction.toggleDashboard.title
            }
        )
        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected a canonical action")
        }

        let outcome = await host.actionExecutor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testExcludedAppShortcutsDoNotLeakIntoSearchKeywords() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        for action in [AppShortcutAction.openSettings, .openCommandPalette] {
            XCTAssertFalse(
                index.results(matching: action.title).contains {
                    $0.id == "general-setting.appShortcuts"
                },
                "\(action.title) must not be indexed through shortcut keywords"
            )
        }
    }

    func testAppShortcutsAreNotAutomaticallyPromotedIntoCommands() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        XCTAssertFalse(index.items.contains {
            if case .appHostCommand = $0.action {
                return true
            }
            return false
        })
    }

    func testAppHostCommandCarriesExpectedDefinitionConfirmationAndKeywords() throws {
        let confirmation = MacToolsCommandConfirmation(
            title: "确认命令",
            message: "确认执行此命令。",
            confirmButtonTitle: "执行"
        )
        let definition = AppHostCommandDefinition(
            id: "app-command.test-confirmed",
            title: "测试命令",
            description: "用于验证确认流程。",
            keywords: ["confirmed", "确认"],
            systemImage: "checkmark.circle",
            confirmation: confirmation,
            action: .setLaunchAtLogin(true)
        )
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: []),
            appHostCommandDefinitions: [definition]
        )
        let result = try XCTUnwrap(index.items.first { $0.id == definition.id })

        XCTAssertEqual(result.action, .appHostCommand(expectedDefinition: definition))
        XCTAssertEqual(result.confirmation, confirmation)
        XCTAssertEqual(
            MacToolsSearchActivationDecision.resolve(for: result),
            .confirm(confirmation)
        )
        XCTAssertEqual(index.results(matching: "confirmed").first?.id, definition.id)
        XCTAssertEqual(index.results(matching: "确认").first?.id, definition.id)
    }

    func testModelAutomaticallyRebuildsAfterPluginVisibilityChanges() async throws {
        let plugin = SurfaceOnlySearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let suiteName = "MacToolsSearchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AppHostCommandContext(
            pluginHost: host,
            launchAtLoginController: LaunchAtLoginController(
                service: SearchTestLaunchAtLoginService()
            ),
            appearanceUserDefaults: defaults
        )
        let model = UnifiedSearchPaletteModel(commandContext: context)
        model.updateQuery(plugin.metadata.title)
        let hideAction = AppHostCommandAction.setPluginVisibility(
            pluginID: plugin.metadata.id,
            surface: .featurePanel,
            isVisible: false
        )
        let showAction = AppHostCommandAction.setPluginVisibility(
            pluginID: plugin.metadata.id,
            surface: .featurePanel,
            isVisible: true
        )
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == hideAction
        })
        let (rebuild, cancellable) = expectModelResults(
            model,
            description: "Visibility change rebuilds the command index"
        ) { results in
            results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == showAction
            }
        }

        host.setPluginVisible(false, id: plugin.metadata.id, on: .featurePanel)

        await fulfillment(of: [rebuild], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == showAction
        })
        XCTAssertFalse(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == hideAction
        })
    }

    func testModelAutomaticallyRebuildsAfterLaunchAtLoginChanges() async {
        let suiteName = "MacToolsSearchLaunchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = SearchTestLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service)
        let context = AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: []),
            launchAtLoginController: controller,
            appearanceUserDefaults: defaults
        )
        let model = UnifiedSearchPaletteModel(commandContext: context)
        model.updateQuery("launch at login")
        let (rebuild, cancellable) = expectModelResults(
            model,
            description: "Launch-at-login change rebuilds the command index"
        ) { results in
            results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == .setLaunchAtLogin(false)
            }
        }

        service.isRegistered = true
        controller.refreshStatus()

        await fulfillment(of: [rebuild], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setLaunchAtLogin(false)
        })
        XCTAssertFalse(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setLaunchAtLogin(true)
        })
    }

    func testModelAutomaticallyRebuildsAfterAppearanceChanges() async {
        let suiteName = "MacToolsSearchAppearanceModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let context = AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: []),
            launchAtLoginController: LaunchAtLoginController(
                service: SearchTestLaunchAtLoginService()
            ),
            appearanceUserDefaults: defaults
        )
        let model = UnifiedSearchPaletteModel(commandContext: context)
        model.updateQuery("appearance")
        let (rebuild, cancellable) = expectModelResults(
            model,
            description: "Appearance change rebuilds the command index"
        ) { results in
            results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == .setAppearance(.system)
            } && !results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == .setAppearance(.dark)
            }
        }

        AppAppearancePreference.dark.storeAndApply(in: defaults)

        await fulfillment(of: [rebuild], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(AppAppearancePreference.stored(in: defaults), .dark)
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setAppearance(.system)
        })
        XCTAssertFalse(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setAppearance(.dark)
        })
    }

    private func expectModelResults(
        _ model: UnifiedSearchPaletteModel,
        description: String,
        matching predicate: @escaping ([MacToolsSearchResult]) -> Bool
    ) -> (XCTestExpectation, AnyCancellable) {
        let expectation = expectation(description: description)
        let cancellable = model.$results
            .dropFirst()
            .first(where: predicate)
            .sink { _ in expectation.fulfill() }
        return (expectation, cancellable)
    }

    func testCustomSettingResultCarriesPluginPageAndExactSearchTarget() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == "快捷键目标"
            }
        )

        guard case let .navigate(destination, target) = result.action else {
            return XCTFail("Expected a navigation action")
        }

        XCTAssertEqual(destination, .plugins(.configuration(plugin.metadata.id)))
        XCTAssertEqual(
            target,
            .plugin(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: SearchableTestPlugin.customEntryID
                )
            )
        )
    }

    func testGeneralSettingResultCarriesGeneralPageAndExactSearchTarget() throws {
        let host = makePluginHostForTests(plugins: [])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.id == "general-setting.language"
            }
        )

        XCTAssertEqual(
            result.action,
            .navigate(destination: .general, target: .general(.language))
        )
    }

    func testSurfaceOnlyPluginNavigatesToAndRevealsItsFeaturePanelRow() throws {
        let plugin = SurfaceOnlySearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == plugin.metadata.title
            }
        )

        XCTAssertEqual(
            result.action,
            .navigate(
                destination: .plugins(.featurePanelLayout),
                target: .surface(
                    SurfaceSettingsSearchTarget(
                        surface: .featurePanel,
                        pluginID: plugin.metadata.id
                    )
                )
            )
        )
    }

    func testSearchUsesTitleDescriptionAndKeywordsWithAllTokenMatching() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)

        XCTAssertEqual(
            index.results(matching: "快捷键 目标").first?.title,
            "快捷键目标"
        )
        XCTAssertTrue(
            index.results(matching: "外接 屏幕").contains {
                $0.title == "快捷键目标"
            }
        )
        XCTAssertTrue(index.results(matching: "不存在 屏幕").isEmpty)
    }

    func testEmptyQueryReturnsOnlyOrderedSuggestedDestinations() {
        let host = makePluginHostForTests(plugins: [SearchableTestPlugin()])
        let results = MacToolsSearchIndexBuilder.build(pluginHost: host)
            .results(matching: "  ")

        XCTAssertEqual(
            results.map(\.id),
            [
                "navigation.dashboard",
                "navigation.feature-panel",
                "navigation.actions-and-shortcuts",
                "navigation.automation",
                "navigation.marketplace",
                "navigation.general",
                "navigation.about"
            ]
        )
        XCTAssertTrue(results.allSatisfy { $0.kind == .navigation })
    }

    func testFeatureNavigationUsesRuntimeLocalizedTitles() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        XCTAssertEqual(
            index.results(matching: FeatureL10n.string("操作与快捷键")).first?.id,
            "navigation.actions-and-shortcuts"
        )
        XCTAssertEqual(
            index.results(matching: FeatureL10n.string("自动化")).first?.id,
            "navigation.automation"
        )
    }

    func testPresentationOrderMatchesVisibleGroupsAndQuickSelectionNumbers() {
        let navigation = searchResult(id: "navigation", kind: .navigation)
        let setting = searchResult(id: "setting", kind: .setting)
        let command = searchResult(id: "command", kind: .command)
        let ordered = MacToolsSearchPresentation.orderedResults([
            command,
            navigation,
            setting
        ])

        XCTAssertEqual(ordered.map(\.id), ["navigation", "setting", "command"])
        XCTAssertEqual(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "setting",
                in: ordered
            ),
            2
        )
        XCTAssertNil(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "missing",
                in: ordered
            )
        )
    }

    func testSearchIndexUsesUniqueStableIdentifiers() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [SearchableTestPlugin()])
        )

        XCTAssertEqual(Set(index.items.map(\.id)).count, index.items.count)
    }

    func testUnifiedSearchFieldLeavesTabForInlineControlNavigation() {
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertTab(_:)),
                hasMarkedText: false
            )
        )
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertBacktab(_:)),
                hasMarkedText: false
            )
        )
        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                modifierFlags: .command
            ),
            .openOwner
        )
        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                hasMarkedText: false
            ),
            .openOwner
        )
        XCTAssertTrue(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 36,
            modifierFlags: .command
        ))
        XCTAssertTrue(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 76,
            modifierFlags: [.command, .shift]
        ))
        XCTAssertFalse(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 36,
            modifierFlags: []
        ))
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertTab(_:)),
                hasMarkedText: true
            )
        )
    }

    func testPluginHostPerformsOnlyDeclaredCommands() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let definition = plugin.commandDefinitions[0]

        XCTAssertTrue(
            host.performCommand(
                pluginID: plugin.metadata.id,
                expectedDefinition: definition
            )
        )
        XCTAssertFalse(
            host.performCommand(
                pluginID: "missing",
                expectedDefinition: definition
            )
        )

        XCTAssertEqual(plugin.performedCommandIDs, ["sleep"])
    }

    func testPluginHostValidatesLiveExactSettingsTargets() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)
        let targets = index.items.compactMap { item -> PluginSettingsSearchTarget? in
            guard
                case let .navigate(_, .plugin(target)) = item.action,
                target.pluginID == plugin.metadata.id
            else {
                return nil
            }
            return target
        }

        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy(host.hasPluginSettingsSearchTarget))
        XCTAssertFalse(
            host.hasPluginSettingsSearchTarget(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: "removed-entry"
                )
            )
        )
    }

    func testInstalledIncompatiblePluginIsDiscoverableInMarketplace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacToolsSearchTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(
            suiteName: "MacToolsSearchTests-\(UUID().uuidString)"
        )!
        let store = PluginPackageStore(
            rootDirectory: root,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let packageURL = store.installedDirectory
            .appendingPathComponent(
                "com.example.future.mactoolsplugin",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: "com.example.future",
            displayName: "Future Plugin",
            version: "2.0.0",
            minHostVersion: "99.0.0",
            bundleRelativePath: "Future.bundle"
        )
        try JSONEncoder().encode(manifest).write(
            to: packageURL.appendingPathComponent("plugin.json")
        )

        let manager = DynamicPluginManager(packageStore: store)
        let host = makePluginHostForTests(
            plugins: [],
            dynamicPluginManager: manager,
            loadDynamicPluginsOnInit: false
        )
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.id == "plugin.marketplace.com.example.future"
            }
        )

        XCTAssertEqual(result.title, "Future Plugin")
        XCTAssertEqual(
            result.action,
            .navigate(
                destination: .plugins(.marketplace),
                target: .marketplace(
                    MarketplacePluginSearchTarget(
                        pluginID: "com.example.future"
                    )
                )
            )
        )
        XCTAssertTrue(result.detail.contains("99.0.0"))
    }

    func testAppCommandUsesExistingPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        XCTAssertTrue(host.performAppCommand(.toggleDashboard))

        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testAppCommandFailsWithoutPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])

        XCTAssertFalse(host.performAppCommand(.toggleDashboard))
    }

    private func searchResult(
        id: String,
        kind: MacToolsSearchResultKind
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: kind,
            title: id,
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "magnifyingglass",
            action: .navigate(destination: .general, target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private func appHostCommandDefinition(
        id: String,
        action: AppHostCommandAction
    ) -> AppHostCommandDefinition {
        AppHostCommandDefinition(
            id: id,
            title: AppShortcutAction.toggleDashboard.title,
            description: AppShortcutAction.toggleDashboard.description,
            keywords: [],
            systemImage: AppShortcutAction.toggleDashboard.systemImage,
            confirmation: nil,
            action: action
        )
    }
}

@MainActor
private final class SearchTestLaunchAtLoginService: LaunchAtLoginServicing {
    var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}

@MainActor
private final class SearchableTestPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginSettingsSearchProviding,
    PluginCommandProviding
{
    static let customEntryID = "shortcut-target"

    let metadata = PluginMetadata(
        id: "searchable",
        title: "显示工具",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "管理内建和外接显示器亮度"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var performedCommandIDs: [String] = []
    var commandTitle = "让显示器休眠"

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var settingsSections: [PluginSettingsSection] {
        [
            PluginSettingsSection(
                id: "automatic",
                title: "自动切换",
                description: "根据屏幕状态自动切换亮度。",
                status: .init(
                    text: "已开启",
                    systemImage: "checkmark.circle",
                    tone: .positive
                ),
                footnote: nil,
                buttonTitle: nil,
                actionID: nil
            )
        ]
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "accessibility",
                kind: .accessibility,
                title: "辅助功能授权",
                description: "允许控制显示器。"
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "decrease",
                title: "降低亮度",
                description: "降低目标显示器亮度。",
                actionID: "decrease",
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { _ in
            EmptyView()
        }
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: Self.customEntryID,
                title: "快捷键目标",
                description: "选择亮度快捷键控制的外接显示器。",
                keywords: ["屏幕", "作用范围"],
                systemImage: "display.2"
            )
        ]
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "sleep",
                title: commandTitle,
                description: "立即让所有屏幕进入休眠。",
                systemImage: "display"
            )
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handleAction(_ action: PluginPanelAction) {}

    func handleCommand(id: String) {
        performedCommandIDs.append(id)
    }
}

@MainActor
private final class SurfaceOnlySearchTestPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "surface-only",
        title: "锁定屏幕",
        iconName: "lock",
        iconTint: Color(nsColor: .systemGray),
        order: 2,
        defaultDescription: "立即锁定屏幕"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {}
}
