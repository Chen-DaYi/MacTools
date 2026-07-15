import AppKit
import SwiftUI
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostComponentSupportTests: XCTestCase {
    private let suiteName = "PluginHostComponentSupportTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testComponentPanelPluginOnlyAppearsInComponentItems() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["component"])
        XCTAssertEqual(host.featureManagementItems.map(\.presentation), [.componentPanel])
    }

    func testRefreshingLocalizationDiscardsCachedComponentViewsWithoutRefreshingPlugin() {
        let plugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [plugin])

        _ = host.componentViewItem(for: "component", dismiss: {})
        let makeViewCallCount = plugin.makeViewCallCount
        let refreshCallCount = plugin.refreshCallCount

        host.refreshLocalization()

        XCTAssertFalse(host.isComponentViewCached(for: "component"))
        XCTAssertEqual(plugin.makeViewCallCount, makeViewCallCount)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertEqual(plugin.localizationRefreshCount, 1)
        XCTAssertTrue(host.componentItems.first?.isActive == false)
    }

    func testTwoLocalizationRefreshesPreservePluginState() {
        let plugin = MockComponentPanelPlugin(id: "component", isActive: true)
        let host = makeHost(plugins: [plugin])
        let refreshCallCount = plugin.refreshCallCount
        let initialRevision = host.localizationRevision

        // Runtime language switches are covered by PluginRuntimeLocalizationTests.
        // Exercise the host refresh twice directly so this state-preservation
        // test is independent of the global locale source shared by parallel tests.
        host.refreshLocalization()
        host.refreshLocalization()

        XCTAssertEqual(host.localizationRevision, initialRevision + 2)
        XCTAssertEqual(plugin.refreshCallCount, refreshCallCount)
        XCTAssertEqual(plugin.localizationRefreshCount, 2)
        XCTAssertTrue(host.componentItems.first?.isActive == true)
    }

    func testInstalledComponentRemainsOnItsSupportedSurface() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.componentItems.map(\.id), ["component"])
        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["component"])
    }

    func testComponentOrderUsesDashboardDisplayPreferences() {
        let first = MockComponentPanelPlugin(id: "first", order: 1)
        let second = MockComponentPanelPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["second", "first"])
    }

    func testDisplayPreferencesReadingWithEmptyDefaultPluginIDsDoesNotDiscardStoredOrder() {
        let store = makeDisplayPreferencesStore()
        store.setOrderedPluginIDs(["second", "first"], defaultPluginIDs: ["first", "second"])

        XCTAssertTrue(store.orderedPluginIDs(defaultPluginIDs: []).isEmpty)
        XCTAssertEqual(
            store.orderedPluginIDs(defaultPluginIDs: ["first", "second"]),
            ["second", "first"]
        )
    }

    func testDisplayPreferencesReadingWithPartialDefaultPluginIDsDoesNotDiscardMissingPluginOrder() {
        let store = makeDisplayPreferencesStore()
        store.setOrderedPluginIDs(["third", "second", "first"], defaultPluginIDs: ["first", "second", "third"])

        XCTAssertEqual(
            store.orderedPluginIDs(defaultPluginIDs: ["first"]),
            ["first"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(defaultPluginIDs: ["first", "second", "third"]),
            ["third", "second", "first"]
        )
    }

    func testDisplayPreferencesRemovingPluginClearsLegacyMigrationState() {
        let store = makeDisplayPreferencesStore()
        store.addPendingLegacyDisabledPluginIDs(["dynamic"])
        store.removePlugin("dynamic")

        XCTAssertTrue(store.pendingLegacyDisabledPluginIDs(availablePluginIDs: ["dynamic"]).isEmpty)
    }

    func testComponentOnlyPluginContributesSettingsPermissionsAndShortcuts() {
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ],
            settingsSections: [
                PluginSettingsSection(
                    id: "settings",
                    title: "组件设置",
                    description: "组件设置说明。",
                    status: .init(text: "正常", systemImage: "checkmark", tone: .positive),
                    footnote: nil,
                    buttonTitle: "执行",
                    actionID: "settings-action"
                )
            ],
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "shortcut",
                    title: "组件快捷键",
                    description: "触发组件动作。",
                    actionID: "shortcut-action",
                    scope: .whilePluginActive,
                    defaultBinding: nil,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.permissionCards.map(\.pluginID), ["component"])
        XCTAssertEqual(host.permissionCards.map(\.iconSystemImage), ["accessibility"])
        XCTAssertEqual(host.permissionCards.map(\.iconVisualScale), [1.0])
        XCTAssertEqual(host.settingsCards.map(\.pluginID), ["component"])
        XCTAssertEqual(host.shortcutItems.map(\.pluginID), ["component"])
        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["component"])
        XCTAssertEqual(host.pluginConfigurationItems.first?.settingsCards.map(\.id), ["component.settings"])
        XCTAssertEqual(host.pluginConfigurationItems.first?.permissionCards.map(\.permissionID), ["accessibility"])
        XCTAssertEqual(host.pluginConfigurationItems.first?.shortcutItems.map(\.pluginID), ["component"])
    }

    func testShortcutItemsCarryOptionalSettingsGroupingMetadata() {
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "display-down",
                    title: "降低亮度",
                    description: "降低亮度。",
                    actionID: "display-down",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down",
                    settingsGroupID: "display.one",
                    settingsGroupTitle: "Studio Display",
                    settingsGroupDescription: "可与其他显示器使用相同快捷键，同时调节。",
                    settingsControlTitle: "降低",
                    settingsControlSystemImage: "sun.min.fill"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])
        let item = host.shortcutItems.first

        XCTAssertEqual(item?.settingsGroupID, "display.one")
        XCTAssertEqual(item?.settingsGroupTitle, "Studio Display")
        XCTAssertEqual(item?.settingsGroupDescription, "可与其他显示器使用相同快捷键，同时调节。")
        XCTAssertEqual(item?.settingsControlTitle, "降低")
        XCTAssertEqual(item?.settingsControlSystemImage, "sun.min.fill")
    }

    func testShortcutsInSameSharedBindingGroupCanUseSameBinding() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testShortcutsInDifferentSharedBindingGroupsStillRejectDuplicateBindings() {
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "first",
                    title: "第一个",
                    description: "第一个动作。",
                    actionID: "first",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.down"
                ),
                PluginShortcutDefinition(
                    id: "second",
                    title: "第二个",
                    description: "第二个动作。",
                    actionID: "second",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false,
                    sharedBindingGroupID: "brightness.up"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setShortcutBinding(binding, for: "component.shortcut.first")
        host.setShortcutBinding(binding, for: "component.shortcut.second")

        XCTAssertNotNil(host.shortcutItems.first { $0.id == "component.shortcut.second" }?.errorMessage)
    }

    func testOpenSettingsShortcutCanBeConfiguredAndCleared() {
        let host = makeHost(plugins: [])
        let binding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option])

        XCTAssertNil(host.setOpenSettingsShortcutBindingAndReturnError(binding))
        XCTAssertEqual(host.openSettingsShortcut.bindingText, ShortcutFormatter.displayString(for: binding))
        XCTAssertTrue(host.openSettingsShortcut.canClear)
        XCTAssertNil(host.openSettingsShortcut.errorMessage)

        host.clearOpenSettingsShortcut()

        XCTAssertEqual(host.openSettingsShortcut.bindingText, ShortcutFormatter.displayString(for: nil))
        XCTAssertFalse(host.openSettingsShortcut.canClear)
    }

    func testHostNotifiesDynamicShortcutPluginAfterAcceptingBinding() {
        let plugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "dynamic-device",
                    title: "iPad",
                    description: "Connect the iPad.",
                    actionID: "dynamic-device",
                    scope: .global,
                    defaultBinding: nil,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [plugin])
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])

        host.setShortcutBinding(binding, for: "component.shortcut.dynamic-device")

        XCTAssertEqual(
            plugin.shortcutBindingChanges,
            [.init(id: "dynamic-device", binding: binding)]
        )
    }

    func testOpenSettingsShortcutAcceptsFunctionKeyWithoutModifier() {
        let host = makeHost(plugins: [])
        let binding = ShortcutBinding(keyCode: UInt16(kVK_F1), modifiers: [])

        XCTAssertNil(host.setOpenSettingsShortcutBindingAndReturnError(binding))
        XCTAssertEqual(host.openSettingsShortcut.bindingText, ShortcutFormatter.displayString(for: binding))
        XCTAssertTrue(host.openSettingsShortcut.canClear)
        XCTAssertNil(host.openSettingsShortcut.errorMessage)
    }

    func testOpenSettingsShortcutRejectsRegularKeyWithoutModifier() {
        let host = makeHost(plugins: [])
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])

        XCTAssertEqual(
            host.setOpenSettingsShortcutBindingAndReturnError(binding),
            ShortcutValidationError.missingModifier.localizedDescription
        )
        XCTAssertEqual(
            host.openSettingsShortcut.errorMessage,
            ShortcutValidationError.missingModifier.localizedDescription
        )
        XCTAssertFalse(host.openSettingsShortcut.canClear)
    }

    func testOpenSettingsShortcutRejectsPluginShortcutBinding() {
        let binding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        let plugin = MockComponentPanelPlugin(
            id: "component",
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "shortcut",
                    title: "组件快捷键",
                    description: "触发组件动作。",
                    actionID: "shortcut-action",
                    scope: .global,
                    defaultBinding: binding,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [plugin])

        XCTAssertNotNil(host.setOpenSettingsShortcutBindingAndReturnError(binding))
        XCTAssertNotNil(host.openSettingsShortcut.errorMessage)
        XCTAssertFalse(host.openSettingsShortcut.canClear)
    }

    func testPluginsWithoutConfigurationSurfaceAreHiddenFromConfigurationList() {
        let primaryPanelPlugin = MockPrimaryPanelPlugin(id: "feature")
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(
            plugins: [primaryPanelPlugin, componentPanelPlugin]
        )

        XCTAssertTrue(host.pluginConfigurationItems.isEmpty)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .dashboardLayout)
    }

    func testConfigurationListUsesSharedPluginOrderAndSelectsFirstItem() {
        let first = MockComponentPanelPlugin(
            id: "first",
            order: 1,
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "first-permission",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ]
        )
        let second = MockComponentPanelPlugin(
            id: "second",
            order: 2,
            shortcutDefinitions: [
                PluginShortcutDefinition(
                    id: "second-shortcut",
                    title: "快捷键",
                    description: "触发动作。",
                    actionID: "shortcut-action",
                    scope: .whilePluginActive,
                    defaultBinding: nil,
                    isRequired: false
                )
            ]
        )
        let host = makeHost(plugins: [first, second])

        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["first", "second"])
        XCTAssertEqual(host.selectedFeatureSettingsPane, .dashboardLayout)

        host.moveFeatureManagementItem(id: "second", toOffset: 0)

        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.selectedFeatureSettingsPane, .dashboardLayout)
    }

    func testFeatureSettingsSelectionIgnoresMissingConfigurationItem() {
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            permissionRequirements: [
                PluginPermissionRequirement(
                    id: "accessibility",
                    kind: .accessibility,
                    title: "辅助功能",
                    description: "需要辅助功能权限。"
                )
            ]
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        host.selectFeatureSettingsPane(.configuration("missing"))

        XCTAssertEqual(host.selectedFeatureSettingsPane, .dashboardLayout)

        host.selectFeatureSettingsPane(.configuration("component"))

        XCTAssertEqual(host.selectedFeatureSettingsPane, .configuration("component"))
    }

    func testCustomPluginConfigurationContributesConfigurationItemAndCachesView() {
        let configurationCounter = ConfigurationRenderCounter()
        let componentPanelPlugin = MockComponentPanelPlugin(
            id: "component",
            configuration: PluginConfiguration(description: "自定义配置") { context in
                configurationCounter.makeView(context: context)
            }
        )
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["component"])
        XCTAssertEqual(host.pluginConfigurationItems.first?.description, "自定义配置")
        XCTAssertEqual(host.pluginConfigurationItems.first?.hasCustomConfiguration, true)

        _ = host.pluginConfigurationViewItem(for: "component")
        _ = host.pluginConfigurationViewItem(for: "component")

        XCTAssertEqual(configurationCounter.callCount, 1)
    }

    func testPluginStateChangesAreCoalescedAndInvalidateDirtyConfigurationViewCache() async {
        let configurationCounter = ConfigurationRenderCounter()
        let componentPanelPlugin = MutableComponentPanelPlugin(
            id: "component",
            configuration: PluginConfiguration(description: "自定义配置") { context in
                configurationCounter.makeView(context: context)
            }
        )
        let host = makeHost(
            plugins: [componentPanelPlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )

        _ = host.pluginConfigurationViewItem(for: "component")
        XCTAssertEqual(configurationCounter.callCount, 1)
        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 1)

        componentPanelPlugin.isActive = true
        componentPanelPlugin.triggerStateChange()
        componentPanelPlugin.triggerStateChange()
        componentPanelPlugin.triggerStateChange()

        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 1)

        for _ in 0..<20 where componentPanelPlugin.componentStateReadCount < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(componentPanelPlugin.componentStateReadCount, 2)
        XCTAssertEqual(host.featureManagementItems.first?.isActive, true)

        _ = host.pluginConfigurationViewItem(for: "component")

        XCTAssertEqual(configurationCounter.callCount, 2)
    }

    func testPluginStateChangesOnlyReadDirtyPanelState() async throws {
        let changingPlugin = CountingPrimaryPanelPlugin(id: "changing", order: 1)
        let stablePlugin = CountingPrimaryPanelPlugin(id: "stable", order: 2)
        let host = makeHost(
            plugins: [changingPlugin, stablePlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
        changingPlugin.panelStateReadCount = 0
        stablePlugin.panelStateReadCount = 0

        changingPlugin.primarySubtitle = "changed"
        changingPlugin.onStateChange?()
        changingPlugin.primarySubtitle = "changed again"
        changingPlugin.onStateChange?()
        changingPlugin.onStateChange?()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(changingPlugin.panelStateReadCount, 1)
        XCTAssertEqual(stablePlugin.panelStateReadCount, 0)
        XCTAssertEqual(host.panelItems.map(\.description), ["changed again", "Feature stable"])
    }

    func testComponentActiveStateContributesToHasActivePlugin() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component", isActive: true)
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.hasActivePlugin)
        XCTAssertEqual(host.featureManagementItems.first?.isActive, true)
    }

    func testComponentViewsAreCachedForFastPanelPresentation() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertFalse(host.isComponentViewCached(for: "component"))

        let first = host.componentViewItem(for: "component", dismiss: {})
        let second = host.componentViewItem(for: "component", dismiss: {})

        XCTAssertEqual(first.id, "component")
        XCTAssertEqual(second.id, "component")
        XCTAssertEqual(componentPanelPlugin.makeViewCallCount, 1)
        XCTAssertTrue(host.isComponentViewCached(for: "component"))
    }

    func testDiscardComponentViewsReleasesCachedComponentContent() {
        let first = MockComponentPanelPlugin(id: "first", order: 1)
        let second = MockComponentPanelPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        _ = host.componentViewItem(for: "first", dismiss: {})
        _ = host.componentViewItem(for: "second", dismiss: {})
        host.discardComponentViews()
        _ = host.componentViewItem(for: "first", dismiss: {})
        _ = host.componentViewItem(for: "second", dismiss: {})

        XCTAssertEqual(first.makeViewCallCount, 2)
        XCTAssertEqual(second.makeViewCallCount, 2)
    }

    func testComponentContextUsesVisiblePresentationForCachedViews() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        _ = host.componentViewItem(for: "component", dismiss: {})

        XCTAssertEqual(componentPanelPlugin.receivedPanelVisibilityValues, [true])
    }

    func testPrewarmingComponentViewsBuildsStableVisiblePresentationOnce() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.prewarmComponentViews(dismiss: {})
        _ = host.componentViewItem(for: "component", dismiss: {})

        XCTAssertEqual(componentPanelPlugin.makeViewCallCount, 1)
        XCTAssertEqual(componentPanelPlugin.receivedPanelVisibilityValues, [true])
        XCTAssertTrue(host.isComponentViewCached(for: "component"))
    }

    func testComponentSurfaceLifecycleEventsAreSentWhenPanelVisibilityChanges() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setPanelSurface(.component, visible: true)
        host.setPanelSurface(.component, visible: true)
        host.setPanelSurface(.component, visible: false)
        host.setPanelSurface(.component, visible: false)

        XCTAssertEqual(componentPanelPlugin.surfaceEvents, [
            .visible(.component),
            .hidden(.component)
        ])
    }

    func testPrimaryPanelPluginAppearsOnlyInPanelItems() {
        let primaryPanelPlugin = MockPrimaryPanelPlugin(id: "feature")
        let host = makeHost(plugins: [primaryPanelPlugin])

        XCTAssertEqual(host.panelItems.map(\.id), ["feature"])
        XCTAssertTrue(host.componentItems.isEmpty)
        XCTAssertEqual(host.featureManagementItems.map(\.presentation), [.featurePanel])
    }

    func testPluginCanContributeFeatureAndComponentPanels() {
        let plugin = MockCombinedPlugin(id: "combined")
        let host = makeHost(plugins: [plugin])

        XCTAssertEqual(host.panelItems.map(\.id), ["combined"])
        XCTAssertEqual(host.componentItems.map(\.id), ["combined"])
        XCTAssertEqual(host.featureManagementItems.map(\.presentation), [.featureAndComponentPanel])
    }

    func testHostClassifiesDashboardFeatureDualAndSettingsOnlyPluginsExactly() {
        let dashboard = MockComponentPanelPlugin(id: "dashboard", order: 1)
        let feature = MockPrimaryPanelPlugin(id: "feature", order: 2)
        let dual = MockCombinedPlugin(id: "dual", order: 3)
        let settingsOnly = MockSettingsOnlyPlugin(id: "settings", order: 4)
        let host = makeHost(plugins: [dashboard, feature, dual, settingsOnly])

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["dashboard", "dual"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["feature", "dual"])
        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["settings"])
        XCTAssertFalse(host.featureManagementItems.contains { $0.id == "settings" })
    }

    func testSurfaceOrdersAreIndependentInDerivedPanelItems() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["first", "second"])

        host.movePlugin(id: "second", toOffset: 0, on: .featurePanel)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["second", "first"])
    }

    func testSurfaceOrderReordersEveryInstalledPlugin() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let third = MockCombinedPlugin(id: "third", order: 3)
        let host = makeHost(plugins: [first, second, third])

        host.movePlugin(id: "third", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["third", "first", "second"])
        XCTAssertEqual(host.componentItems.map(\.id), ["third", "first", "second"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(host.panelItems.map(\.id), ["first", "second", "third"])
    }

    func testSurfaceReorderUsesSurfaceLocalOffsets() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let third = MockCombinedPlugin(id: "third", order: 3)
        let fourth = MockCombinedPlugin(id: "fourth", order: 4)
        let host = makeHost(plugins: [first, second, third, fourth])

        host.movePlugin(id: "fourth", toOffset: 1, on: .dashboard)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["first", "fourth", "second", "third"])
        XCTAssertEqual(host.componentItems.map(\.id), ["first", "fourth", "second", "third"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["first", "second", "third", "fourth"])
        XCTAssertEqual(host.panelItems.map(\.id), ["first", "second", "third", "fourth"])
    }

    func testResettingDashboardOrderPreservesFeaturePanelOrder() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])
        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)
        host.movePlugin(id: "second", toOffset: 0, on: .featurePanel)
        host.resetPluginOrder(on: .dashboard)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["first", "second"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.componentItems.map(\.id), ["first", "second"])
        XCTAssertEqual(host.panelItems.map(\.id), ["second", "first"])
    }

    func testSurfaceOrderingIgnoresMissingPlugins() {
        let plugin = MockComponentPanelPlugin(id: "dashboard")
        let host = makeHost(plugins: [plugin])

        host.movePlugin(id: "missing", toOffset: 0, on: .dashboard)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["dashboard"])
        XCTAssertEqual(host.componentItems.map(\.id), ["dashboard"])
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
    }

    func testInstalledDualPluginAppearsOnBothSupportedSurfaces() {
        let plugin = MockCombinedPlugin(id: "dual")
        let host = makeHost(plugins: [plugin])

        XCTAssertEqual(host.componentItems.map(\.id), ["dual"])
        XCTAssertEqual(host.panelItems.map(\.id), ["dual"])
    }

    func testInstalledPluginContributesToHostActiveState() {
        let plugin = MockComponentPanelPlugin(id: "active", isActive: true)
        let host = makeHost(plugins: [plugin])

        XCTAssertTrue(host.hasActivePlugin)
    }

    func testDynamicPluginManagerCanRemoveInstalledPluginFromDerivedState() {
        let firstPlugin = MockPrimaryPanelPlugin(id: "dynamic")
        let secondPlugin = MockPrimaryPanelPlugin(id: "second")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        let dynamicRecord = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true),
            store: store
        )
        _ = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(primaryPanel: true),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                let plugin = record.id == "dynamic" ? firstPlugin : secondPlugin

                return DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: loader
        )
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.panelItems.map(\.id), ["dynamic", "second"])

        try? FileManager.default.removeItem(at: dynamicRecord.packageURL)
        manager.reloadInstalledPlugins()

        XCTAssertEqual(host.panelItems.map(\.id), ["second"])
        XCTAssertEqual(host.featureManagementItems.map(\.id), ["second"])
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testUninstallingDynamicPluginRemovesLayoutAndShortcutReferences() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let packageStore = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true),
            store: packageStore
        )
        let shortcutDefinition = PluginShortcutDefinition(
            id: "open",
            title: "Open",
            description: "Open the dynamic plugin.",
            actionID: "open",
            scope: .global,
            defaultBinding: nil,
            isRequired: false
        )
        let plugin = MockPrimaryPanelPlugin(
            id: "dynamic",
            shortcutDefinitions: [shortcutDefinition]
        )
        let manager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: StubDynamicPluginLoader { records in
                records.map { record in
                    DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
                }
            }
        )
        let shortcutStore = ShortcutStore(userDefaults: defaults)
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: shortcutStore,
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
        let shortcutID = "dynamic.shortcut.open"
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: shortcutID
        )

        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["dynamic"])
        XCTAssertNotNil(shortcutStore.customizations(for: [shortcutID])[shortcutID])

        try host.uninstallDynamicPlugin(pluginID: "dynamic")

        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.shortcutItems.isEmpty)
        XCTAssertTrue(shortcutStore.customizations(for: [shortcutID]).isEmpty)
        XCTAssertTrue(packageStore.installedRecords().isEmpty)
    }

    func testReinstalledDynamicPluginRestoresDashboardPositionAndVisibility() {
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "first",
            bundleName: "First.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        let secondRecord = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [record.id == "first" ? first : second],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)
        host.movePlugin(id: "second", toOffset: 0, on: .dashboard)
        try? FileManager.default.removeItem(at: secondRecord.packageURL)
        manager.reloadInstalledPlugins()

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["first"])

        _ = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        manager.reloadInstalledPlugins()

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["first", "second"])
    }

    func testDynamicPluginConfigurationGetterIsNotReadWhenManifestDoesNotDeclareConfiguration() {
        let plugin = ConfigurationTrapPlugin(id: "dynamic")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true, configuration: false),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: loader
        )
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.panelItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.pluginConfigurationItems.isEmpty)
        XCTAssertEqual(plugin.configurationReadCount, 0)
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func testDynamicSettingsOnlyPluginAppearsOnlyInConfigurationList() {
        let plugin = MockSettingsOnlyPlugin(id: "settings-only", order: 1)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "settings-only",
            bundleName: "SettingsOnly.bundle",
            capabilities: .init(configuration: true),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["settings-only"])
        XCTAssertTrue(host.dashboardLayoutItems.isEmpty)
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertTrue(host.componentItems.isEmpty)
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertTrue(host.featureManagementItems.isEmpty)
    }

    func testDeferredDynamicLoadingMigratesLegacyOrderIntoBothSurfaces() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "first",
            bundleName: "First.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        _ = installTestPluginPackage(
            id: "second",
            bundleName: "Second.bundle",
            capabilities: .init(primaryPanel: true, componentPanel: true),
            store: store
        )
        let first = MockCombinedPlugin(id: "first", order: 1)
        let second = MockCombinedPlugin(id: "second", order: 2)
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [record.id == "first" ? first : second],
                    errorMessage: nil
                )
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let legacyData = try JSONEncoder().encode(
            LegacyDisplayPreferencesFixture(
                orderedPluginIDs: ["second", "first"],
                hiddenPluginIDs: []
            )
        )
        defaults.set(legacyData, forKey: "plugin.display.preferences")
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )

        XCTAssertTrue(host.dashboardLayoutItems.isEmpty)
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)

        host.loadDynamicPluginsIfNeeded()

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.panelItems.map(\.id), ["second", "first"])
    }

    func testLegacyGlobalDisabledPreferenceDoesNotLoadDynamicPluginBeforeMigrationReview() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: true),
            store: store
        )
        let plugin = MockPrimaryPanelPlugin(id: "dynamic")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let legacyData = try JSONEncoder().encode(
            LegacyDisplayPreferencesFixture(
                orderedPluginIDs: ["dynamic"],
                hiddenPluginIDs: ["dynamic"]
            )
        )
        defaults.set(legacyData, forKey: "plugin.display.preferences")
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = PluginHost(
            plugins: [],
            dynamicPluginManager: manager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .legacyDisabled)
        XCTAssertEqual(host.pendingLegacyDisabledPluginIDs, Set(["dynamic"]))

        try host.resolveLegacyDisabledPlugin("dynamic", keepInstalled: true)

        XCTAssertEqual(host.panelItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.pendingLegacyDisabledPluginIDs.isEmpty)

        let importedLegacyBackup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["dynamic"],
                hiddenPluginIDs: ["dynamic"]
            ),
            shortcutCustomizations: [:]
        )

        _ = try host.importPreferences(importedLegacyBackup)

        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .legacyDisabled)
        XCTAssertEqual(host.pendingLegacyDisabledPluginIDs, Set(["dynamic"]))
    }

    func testDynamicPanelCapabilityMismatchExposesOnlyManifestAndRuntimeIntersection() {
        let plugin = MockCombinedPlugin(id: "dynamic")
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginHostComponentSupportTests-\(UUID().uuidString)")
        let store = PluginPackageStore(
            rootDirectory: rootDirectory,
            userDefaults: UserDefaults(suiteName: suiteName)!,
            hostVersion: "1.0.0"
        )
        _ = installTestPluginPackage(
            id: "dynamic",
            bundleName: "Dynamic.bundle",
            capabilities: .init(primaryPanel: false, componentPanel: true),
            store: store
        )
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        let host = makeHost(plugins: [], dynamicPluginManager: manager)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.featurePanelLayoutItems.isEmpty)
        XCTAssertEqual(host.componentItems.map(\.id), ["dynamic"])
        XCTAssertTrue(host.panelItems.isEmpty)
        XCTAssertEqual(
            host.dashboardLayoutItems.first?.capabilities,
            PluginHostCapabilities(
                supportsDashboard: true,
                supportsFeaturePanel: false,
                hasCustomConfiguration: false
            )
        )
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private func makeHost(
        plugins: [any MacToolsPlugin] = [],
        dynamicPluginManager: DynamicPluginManager? = nil,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80)
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            dynamicPluginManager: dynamicPluginManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: displayConfigurationObserver,
            displayTopologyRefreshDelay: displayTopologyRefreshDelay,
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay
        )
    }

    private func makeDisplayPreferencesStore() -> PluginDisplayPreferencesStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PluginDisplayPreferencesStore(userDefaults: defaults)
    }

    private func installTestPluginPackage(
        id: String,
        bundleName: String,
        capabilities: PluginPackageManifest.Capabilities = .init(),
        store: PluginPackageStore
    ) -> PluginPackageRecord {
        let sourceURL = store.rootDirectory
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = sourceURL.appendingPathComponent(bundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: id,
            version: "1.0.0",
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleName,
            capabilities: capabilities
        )
        let data = try? JSONEncoder().encode(manifest)
        try? data?.write(to: sourceURL.appendingPathComponent("plugin.json"))

        return try! store.installPackage(from: sourceURL)
    }
}

private struct LegacyDisplayPreferencesFixture: Codable {
    let orderedPluginIDs: [String]
    let hiddenPluginIDs: Set<String>
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDs: [String] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDs = records.map(\.id)
        return handler(records)
    }
}

@MainActor
private final class MockDisplayConfigurationObserver: DisplayConfigurationObserving {
    var onConfigurationChange: (() -> Void)?

    func triggerChange() {
        onConfigurationChange?()
    }
}

@MainActor
private final class MockComponentPanelPlugin: MacToolsPlugin, PluginComponentPanel,
    PluginPanelSurfaceLifecycleHandling, PluginRuntimeLocalizationRefreshing, PluginShortcutBindingChangeHandling {
    struct ShortcutBindingChange: Equatable {
        let id: String
        let binding: ShortcutBinding?
    }
    enum SurfaceEvent: Equatable {
        case visible(PluginPanelSurface)
        case hidden(PluginPanelSurface)
    }

    let metadata: PluginMetadata
    let descriptor: PluginComponentDescriptor
    let permissionRequirements: [PluginPermissionRequirement]
    let settingsSections: [PluginSettingsSection]
    let shortcutDefinitions: [PluginShortcutDefinition]
    let configuration: PluginConfiguration?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private let isActive: Bool
    private(set) var makeViewCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var localizationRefreshCount = 0
    private(set) var receivedPanelVisibilityValues: [Bool] = []
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var shortcutBindingChanges: [ShortcutBindingChange] = []

    init(
        id: String,
        order: Int = 1,
        span: PluginComponentSpan = .oneByOne,
        isActive: Bool = false,
        permissionRequirements: [PluginPermissionRequirement] = [],
        settingsSections: [PluginSettingsSection] = [],
        shortcutDefinitions: [PluginShortcutDefinition] = [],
        configuration: PluginConfiguration? = nil
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Component \(id)"
        )
        self.descriptor = PluginComponentDescriptor(span: span)
        self.isActive = isActive
        self.permissionRequirements = permissionRequirements
        self.settingsSections = settingsSections
        self.shortcutDefinitions = shortcutDefinitions
        self.configuration = configuration
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        makeViewCallCount += 1
        receivedPanelVisibilityValues.append(context.isPanelVisible)
        return AnyView(Text(context.pluginID))
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.visible(surface))
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.hidden(surface))
    }

    func refresh() {
        refreshCallCount += 1
    }

    func refreshLocalization() {
        localizationRefreshCount += 1
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        shortcutBindingChanges.append(.init(id: id, binding: binding))
    }
}

@MainActor
private final class MutableComponentPanelPlugin: MacToolsPlugin, PluginComponentPanel {
    let metadata: PluginMetadata
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    let configuration: PluginConfiguration?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var isActive = false
    var onComponentStateRead: (() -> Void)?
    private(set) var componentStateReadCount = 0

    init(id: String, configuration: PluginConfiguration? = nil) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: 1,
            defaultDescription: "Component \(id)"
        )
        self.configuration = configuration
    }

    var componentPanelState: PluginComponentState {
        componentStateReadCount += 1
        onComponentStateRead?()
        return PluginComponentState(
            subtitle: "Component subtitle",
            isActive: isActive,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func triggerStateChange() {
        onStateChange?()
    }
}

@MainActor
private final class ConfigurationRenderCounter {
    private(set) var callCount = 0

    func makeView(context: PluginConfigurationContext) -> AnyView {
        callCount += 1
        return AnyView(Text(context.pluginID))
    }
}

@MainActor
private final class MockPrimaryPanelPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var refreshCallCount = 0
    private let definedShortcuts: [PluginShortcutDefinition]

    init(
        id: String,
        order: Int = 1,
        shortcutDefinitions: [PluginShortcutDefinition] = []
    ) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.definedShortcuts = shortcutDefinitions
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Feature subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { definedShortcuts }

    func refresh() {
        refreshCallCount += 1
    }
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class CountingPrimaryPanelPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var primarySubtitle: String
    var panelStateReadCount = 0

    init(id: String, order: Int) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Feature \(id)"
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        self.primarySubtitle = ""
    }

    var primaryPanelState: PluginPanelState {
        panelStateReadCount += 1
        return PluginPanelState(
            subtitle: primarySubtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}
    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class ConfigurationTrapPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling,
        buttonTitle: "执行"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var configurationReadCount = 0

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemIndigo),
            order: 1,
            defaultDescription: "Dynamic \(id)"
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Dynamic subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var configuration: PluginConfiguration? {
        configurationReadCount += 1
        return PluginConfiguration(description: "Should not be read") { _ in
            Text("Unexpected")
        }
    }

    func handleAction(_ action: PluginPanelAction) {}
}

@MainActor
private final class MockCombinedPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel, PluginPanelSurfaceLifecycleHandling {
    enum SurfaceEvent: Equatable {
        case visible(PluginPanelSurface)
        case hidden(PluginPanelSurface)
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var surfaceEvents: [SurfaceEvent] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(id: String, order: Int = 1) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: order,
            defaultDescription: "Combined \(id)"
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Combined subtitle",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Combined component subtitle",
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func handleAction(_ action: PluginPanelAction) {}

    func activate(context: PluginRuntimeContext) {
        activateCallCount += 1
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivateCallCount += 1
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.visible(surface))
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        surfaceEvents.append(.hidden(surface))
    }
}

@MainActor
private final class MockSettingsOnlyPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: Color(nsColor: .systemGray),
            order: order,
            defaultDescription: "Settings \(id)"
        )
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: "Settings only") { _ in
            Text("Settings")
        }
    }
}

@MainActor
private final class MockDisplayTopologyPlugin: MacToolsPlugin, PluginPrimaryPanel, DisplayTopologyRefreshing {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var refreshCallCount = 0
    var refreshDisplayTopologyCallCount = 0

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            order: 1,
            defaultDescription: "Display \(id)"
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .disclosure,
            menuActionBehavior: .keepPresented
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Display subtitle \(refreshDisplayTopologyCallCount)",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        refreshCallCount += 1
    }

    func refreshDisplayTopology() {
        refreshDisplayTopologyCallCount += 1
    }

    func handleAction(_ action: PluginPanelAction) {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
