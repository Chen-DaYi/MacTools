import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class MacToolsSearchTests: XCTestCase {
    func testIndexIncludesNavigationDeclarativeSettingsCustomSettingsAndCommands() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin, SurfaceOnlySearchTestPlugin()])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)

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
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.appearance" && $0.kind == .setting
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.preferencesBackup" && $0.kind == .setting
        })
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

    func testGeneralShortcutSettingMatchesIndividualShortcutTitles() {
        let host = makePluginHostForTests(plugins: [])
        let results = MacToolsSearchIndexBuilder.build(pluginHost: host)
            .results(matching: AppShortcutAction.toggleDashboard.title)

        XCTAssertTrue(results.contains { $0.id == "general-setting.appShortcuts" })
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

    func testExactTitleRanksAheadOfDescriptionOnlyMatch() {
        let exact = MacToolsSearchResult(
            id: "exact",
            kind: .navigation,
            title: "屏幕",
            subtitle: "插件",
            detail: "",
            keywords: [],
            systemImage: "display",
            action: .navigate(destination: .plugins(.marketplace), target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )
        let detailOnly = MacToolsSearchResult(
            id: "detail",
            kind: .setting,
            title: "保持常亮",
            subtitle: "阻止休眠",
            detail: "防止屏幕因空闲而关闭",
            keywords: [],
            systemImage: "coffee",
            action: .navigate(destination: .plugins(.marketplace), target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )

        XCTAssertEqual(
            MacToolsSearchIndex(items: [detailOnly, exact])
                .results(matching: "屏幕")
                .map(\.id),
            ["exact", "detail"]
        )
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
                "navigation.marketplace",
                "navigation.general",
                "navigation.about"
            ]
        )
        XCTAssertTrue(results.allSatisfy { $0.kind == .navigation })
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

    func testQuickSelectionIsLimitedToFirstNineVisibleResults() {
        let results = (1...10).map {
            searchResult(id: "result-\($0)", kind: .setting)
        }

        XCTAssertEqual(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "result-9",
                in: results
            ),
            9
        )
        XCTAssertNil(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "result-10",
                in: results
            )
        )
    }

    func testPaletteModelKeepsOneDerivedResultSnapshotPerQuery() {
        let host = makePluginHostForTests(plugins: [SearchableTestPlugin()])
        let model = UnifiedSearchPaletteModel(pluginHost: host)

        XCTAssertEqual(
            model.results.map(\.id),
            [
                "navigation.dashboard",
                "navigation.feature-panel",
                "navigation.marketplace",
                "navigation.general",
                "navigation.about"
            ]
        )

        model.updateQuery("快捷键目标")
        XCTAssertEqual(model.results.first?.title, "快捷键目标")
    }

    func testUnifiedSearchFieldLeavesCommandsToActiveInputMethod() {
        for selector in [
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.cancelOperation(_:))
        ] {
            XCTAssertNil(
                UnifiedSearchTextField.command(
                    for: selector,
                    hasMarkedText: true
                )
            )
        }

        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.moveDown(_:)),
                hasMarkedText: false
            ),
            .moveSelection(1)
        )
        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false
            ),
            .submit
        )
    }

    func testPaletteLayoutUsesLargerMaximumSizeAndFitsMinimumSettingsWindow() {
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.width(for: 720),
            672
        )
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.width(for: 1_200),
            672
        )
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 480),
            278
        )
        XCTAssertEqual(
            UnifiedSearchPaletteLayout.resultListHeight(for: 800),
            420
        )
    }

    func testPluginHostPerformsOnlyDeclaredCommands() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])

        host.performCommand(pluginID: plugin.metadata.id, commandID: "sleep")
        host.performCommand(pluginID: plugin.metadata.id, commandID: "missing")
        host.performCommand(pluginID: "missing", commandID: "sleep")

        XCTAssertEqual(plugin.performedCommandIDs, ["sleep"])
    }

    func testAppCommandUsesExistingPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        host.performAppCommand(.toggleDashboard)

        XCTAssertEqual(requests, [.toggleDashboard])
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
                title: "让显示器休眠",
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
