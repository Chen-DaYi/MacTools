import AppKit
import Combine
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostDisclosureStateTests: XCTestCase {
    private let suiteName = "PluginHostDisclosureStateTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDisclosureExpansionDoesNotMarkPluginActive() {
        let plugin = MockDisclosurePlugin()
        let host = makeHost(plugin: plugin)

        XCTAssertFalse(host.hasActivePlugin)
        XCTAssertFalse(host.featureManagementItems[0].isActive)
        XCTAssertFalse(host.panelItems[0].isExpanded)

        host.setDisclosureExpanded(true, for: plugin.metadata.id)

        XCTAssertTrue(host.panelItems[0].isExpanded)
        XCTAssertFalse(host.featureManagementItems[0].isActive)
        XCTAssertFalse(host.hasActivePlugin)
    }

    func testErrorMessageMapsToErrorDescriptionTone() {
        let plugin = MockDisclosurePlugin()
        plugin.errorMessage = "切换失败：显示器已断开连接"
        let host = makeHost(plugin: plugin)

        switch host.panelItems[0].descriptionTone {
        case .error:
            break
        case .secondary:
            XCTFail("Expected .error when state.errorMessage is non-nil")
        }
    }

    func testRebuildReadsPanelStateOncePerPlugin() {
        let plugin = MockDisclosurePlugin()
        let host = makeHost(plugin: plugin)
        plugin.stateReadCount = 0

        host.setDisclosureExpanded(true, for: plugin.metadata.id)

        XCTAssertEqual(plugin.stateReadCount, 1)
    }

    func testOptionalPrimaryPanelIndicatorMapsByPluginID() {
        let plugin = MockDisclosurePlugin()
        plugin.indicator = PluginPrimaryPanelIndicator(text: "屏幕常亮", systemImage: "display")
        let host = makeHost(plugin: plugin)

        XCTAssertEqual(host.primaryPanelIndicatorsByID[plugin.metadata.id], plugin.indicator)
    }

    func testIncrementalRebuildDoesNotRereadNilIndicatorForUnrelatedPlugin() async throws {
        let changingPlugin = MockDisclosurePlugin(id: "changing", order: 1)
        let stablePlugin = MockDisclosurePlugin(id: "stable", order: 2)
        let host = makeHost(
            plugins: [changingPlugin, stablePlugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
        changingPlugin.indicatorReadCount = 0
        stablePlugin.indicatorReadCount = 0

        changingPlugin.onStateChange?()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(changingPlugin.indicatorReadCount, 1)
        XCTAssertEqual(stablePlugin.indicatorReadCount, 0)
        XCTAssertTrue(host.primaryPanelIndicatorsByID.isEmpty)
    }

    func testPrimaryPanelIndicatorChangesPublishDirectly() async throws {
        let plugin = MockDisclosurePlugin()
        let host = makeHost(
            plugins: [plugin],
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
        let expectedIndicator = PluginPrimaryPanelIndicator(text: "屏幕常亮", systemImage: "display")
        var publishedIndicators: [[String: PluginPrimaryPanelIndicator]] = []
        let cancellable = host.$primaryPanelIndicatorsByID
            .dropFirst()
            .sink { publishedIndicators.append($0) }

        plugin.indicator = expectedIndicator
        plugin.onStateChange?()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(publishedIndicators.last?[plugin.metadata.id], expectedIndicator)
        withExtendedLifetime(cancellable) {}
    }

    private func makeHost(plugin: MockDisclosurePlugin) -> PluginHost {
        makeHost(plugins: [plugin])
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        pluginStateChangeRebuildDelay: Duration = .milliseconds(80)
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay
        )
    }
}

@MainActor
private final class MockDisclosurePlugin: MacToolsPlugin, PluginPrimaryPanel, PluginPrimaryPanelIndicatorProviding {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var isExpanded = false
    var errorMessage: String?
    var indicator: PluginPrimaryPanelIndicator?
    var stateReadCount = 0
    var indicatorReadCount = 0

    init(id: String = "mock-disclosure", order: Int = 1) {
        metadata = PluginMetadata(
            id: id,
            title: "Mock Disclosure",
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Mock plugin"
        )
    }

    var primaryPanelIndicator: PluginPrimaryPanelIndicator? {
        indicatorReadCount += 1
        return indicator
    }

    var primaryPanelState: PluginPanelState {
        stateReadCount += 1
        return PluginPanelState(
            subtitle: "Mock plugin",
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handleAction(_ action: PluginPanelAction) {
        if case let .setDisclosureExpanded(value) = action {
            isExpanded = value
            onStateChange?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
