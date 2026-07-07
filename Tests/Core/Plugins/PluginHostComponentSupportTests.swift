import AppKit
import SwiftUI
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

    func testComponentVisibilityUsesSharedDisplayPreferences() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        host.setFeatureVisibility(false, for: "component")

        XCTAssertTrue(host.componentItems.isEmpty)
        XCTAssertEqual(host.featureManagementItems.first?.isVisible, false)
    }

    func testComponentOrderUsesSharedDisplayPreferences() {
        let first = MockComponentPanelPlugin(id: "first", order: 1)
        let second = MockComponentPanelPlugin(id: "second", order: 2)
        let host = makeHost(plugins: [first, second])

        host.moveFeatureManagementItem(id: "second", toOffset: 0)

        XCTAssertEqual(host.componentItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.featureManagementItems.map(\.id), ["second", "first"])
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

    func testPluginsWithoutConfigurationSurfaceAreHiddenFromConfigurationList() {
        let primaryPanelPlugin = MockPrimaryPanelPlugin(id: "feature")
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(
            plugins: [primaryPanelPlugin, componentPanelPlugin]
        )

        XCTAssertTrue(host.pluginConfigurationItems.isEmpty)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .installed)
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
        XCTAssertEqual(host.selectedFeatureSettingsPane, .installed)

        host.moveFeatureManagementItem(id: "second", toOffset: 0)

        XCTAssertEqual(host.pluginConfigurationItems.map(\.id), ["second", "first"])
        XCTAssertEqual(host.selectedFeatureSettingsPane, .installed)
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

        XCTAssertEqual(host.selectedFeatureSettingsPane, .installed)

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

    func testComponentActiveStateContributesToHasActivePlugin() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component", isActive: true)
        let host = makeHost(plugins: [componentPanelPlugin])

        XCTAssertTrue(host.hasActivePlugin)
        XCTAssertEqual(host.featureManagementItems.first?.isActive, true)
    }

    func testComponentViewsAreCachedForFastPanelPresentation() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        let first = host.componentViewItem(for: "component", dismiss: {})
        let second = host.componentViewItem(for: "component", dismiss: {})

        XCTAssertEqual(first.id, "component")
        XCTAssertEqual(second.id, "component")
        XCTAssertEqual(componentPanelPlugin.makeViewCallCount, 1)
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

    func testComponentContextCarriesPanelVisibility() {
        let componentPanelPlugin = MockComponentPanelPlugin(id: "component")
        let host = makeHost(plugins: [componentPanelPlugin])

        _ = host.componentViewItem(for: "component", dismiss: {}, isPanelVisible: false)

        XCTAssertEqual(componentPanelPlugin.receivedPanelVisibilityValues, [false])
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

    func testDynamicPluginManagerCanRemoveEnabledPluginFromDerivedState() {
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

    func testDisplayConfigurationChangeRefreshesOnlyDisplayTopologyPlugins() async throws {
        let displayPlugin = MockDisplayTopologyPlugin(id: "display")
        let regularPlugin = MockPrimaryPanelPlugin(id: "feature")
        let observer = MockDisplayConfigurationObserver()
        let host = makeHost(
            plugins: [displayPlugin, regularPlugin],
            displayConfigurationObserver: observer,
            displayTopologyRefreshDelay: .milliseconds(10)
        )
        displayPlugin.refreshDisplayTopologyCallCount = 0
        regularPlugin.refreshCallCount = 0

        observer.triggerChange()

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(displayPlugin.refreshDisplayTopologyCallCount, 1)
        XCTAssertEqual(regularPlugin.refreshCallCount, 0)
        XCTAssertEqual(host.panelItems.map(\.id), ["display", "feature"])
    }

    func testDisplayConfigurationChangesAreDebounced() async throws {
        let displayPlugin = MockDisplayTopologyPlugin(id: "display")
        let observer = MockDisplayConfigurationObserver()
        let host = makeHost(
            plugins: [displayPlugin],
            displayConfigurationObserver: observer,
            displayTopologyRefreshDelay: .milliseconds(20)
        )
        displayPlugin.refreshDisplayTopologyCallCount = 0

        observer.triggerChange()
        observer.triggerChange()
        observer.triggerChange()

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(displayPlugin.refreshDisplayTopologyCallCount, 1)
        XCTAssertEqual(host.panelItems.map(\.id), ["display"])
    }

    func testPluginStateChangesAreDebouncedAndOnlyDirtyPanelStateIsRead() async throws {
        let changingPlugin = CountingPrimaryPanelPlugin(id: "changing", order: 1)
        let stablePlugin = CountingPrimaryPanelPlugin(id: "stable", order: 2)
        let host = makeHost(
            plugins: [changingPlugin, stablePlugin],
            derivedStateRebuildDelay: .milliseconds(20)
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

    func testFeaturePanelVisibilityIsForwardedToObservingPlugins() {
        let observingPlugin = MockFeaturePanelVisibilityPlugin(id: "observing")
        let regularPlugin = MockPrimaryPanelPlugin(id: "regular")
        let host = makeHost(plugins: [observingPlugin, regularPlugin])

        host.setFeaturePanelVisible(true)
        host.setFeaturePanelVisible(false)

        XCTAssertEqual(observingPlugin.receivedVisibilityValues, [true, false])
    }

    private func makeHost(
        plugins: [any MacToolsPlugin] = [],
        dynamicPluginManager: DynamicPluginManager? = nil,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180),
        derivedStateRebuildDelay: Duration = .milliseconds(150)
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            dynamicPluginManager: dynamicPluginManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: displayConfigurationObserver,
            displayTopologyRefreshDelay: displayTopologyRefreshDelay,
            derivedStateRebuildDelay: derivedStateRebuildDelay
        )
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
private final class MockComponentPanelPlugin: MacToolsPlugin, PluginComponentPanel {
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
    private(set) var receivedPanelVisibilityValues: [Bool] = []

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

    func refresh() {}

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
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

    init(id: String, order: Int = 1) {
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
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

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
private final class MockFeaturePanelVisibilityPlugin: MacToolsPlugin, PluginPrimaryPanel, FeaturePanelVisibilityObserving {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var receivedVisibilityValues: [Bool] = []

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            order: 1,
            defaultDescription: "Feature \(id)"
        )
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

    func handleAction(_ action: PluginPanelAction) {}

    func setFeaturePanelVisible(_ isVisible: Bool) {
        receivedVisibilityValues.append(isVisible)
    }
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
private final class MockCombinedPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemPurple),
            order: 1,
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
