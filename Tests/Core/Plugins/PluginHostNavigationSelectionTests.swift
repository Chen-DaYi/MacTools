import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostNavigationSelectionTests: XCTestCase {
    private let suiteName = "PluginHostNavigationSelectionTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetPanelNavigationSelectionValueForwardsNavigationAction() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.setPanelNavigationSelectionValue(
            "display-2",
            controlID: "display-navigation",
            for: plugin.metadata.id
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.setNavigationSelection(controlID: "display-navigation", optionID: "display-2")]
        )
        XCTAssertNotEqual(
            plugin.receivedActions,
            [.setSelection(controlID: "display-navigation", optionID: "display-2")]
        )
    }

    func testClearPanelNavigationSelectionForwardsClearAction() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.clearPanelNavigationSelection(
            controlID: "display-navigation",
            for: plugin.metadata.id
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.clearNavigationSelection(controlID: "display-navigation")]
        )
    }

    func testNavigationListControlKindIsDistinctFromSelectList() {
        let kind = PluginPanelControlKind.navigationList

        if case .selectList = kind {
            XCTFail("Expected navigationList to be distinct from selectList")
        }
    }

    func testInvokePanelActionForwardsInvokeActionToPlugin() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.invokePanelAction(controlID: "open-system-settings", for: plugin.metadata.id)

        XCTAssertEqual(
            plugin.receivedActions,
            [.invokeAction(controlID: "open-system-settings")]
        )
    }

    func testPresentPluginMarketplaceSelectsMarketplaceSettings() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.presentPluginMarketplace()

        XCTAssertEqual(host.selectedSettingsDestination, .pluginConfiguration)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .marketplace)
        XCTAssertEqual(host.settingsPresentationRequestCount, 1)
    }

    func testMarketplaceRemainsThePluginManagementDestination() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.presentPluginMarketplace()

        XCTAssertEqual(host.selectedSettingsDestination, .pluginConfiguration)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .marketplace)
        XCTAssertEqual(host.settingsPresentationRequestCount, 1)
    }

    func testLayoutSettingsDestinationsCanBeSelectedIndependently() {
        let host = makeHost(plugin: MockNavigationPlugin())

        host.selectFeatureSettingsPane(.dashboardLayout)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .dashboardLayout)

        host.selectFeatureSettingsPane(.featurePanelLayout)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .featurePanelLayout)
    }

    func testPluginSettingsLandingUsesMarketplaceForSettingsOnlyPlugins() {
        let host = makeHost(plugins: [MockSettingsOnlyNavigationPlugin()])

        host.selectPluginSettingsLandingPage()

        XCTAssertEqual(host.selectedFeatureSettingsPane, .marketplace)
    }

    func testPluginSettingsLandingUsesCompatibleSurfaceWhenOnlyOneIsAvailable() {
        let dashboardHost = makeHost(plugins: [MockDashboardNavigationPlugin()])
        dashboardHost.selectPluginSettingsLandingPage()
        XCTAssertEqual(dashboardHost.selectedFeatureSettingsPane, .dashboardLayout)

        let featurePanelHost = makeHost(plugins: [MockNavigationPlugin()])
        featurePanelHost.selectPluginSettingsLandingPage()
        XCTAssertEqual(featurePanelHost.selectedFeatureSettingsPane, .featurePanelLayout)
    }

    func testPluginSettingsLandingRestoresSavedSurfaceAfterTemporaryIncompatibility() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let firstHost = makeHost(
            plugins: [MockDashboardNavigationPlugin(), MockNavigationPlugin()],
            defaults: defaults,
            resetDefaults: false
        )
        firstHost.selectFeatureSettingsPane(.featurePanelLayout)

        let secondHost = makeHost(
            plugins: [MockDashboardNavigationPlugin()],
            defaults: defaults,
            resetDefaults: false
        )
        secondHost.selectPluginSettingsLandingPage()

        XCTAssertEqual(secondHost.selectedFeatureSettingsPane, .dashboardLayout)

        let thirdHost = makeHost(
            plugins: [MockDashboardNavigationPlugin(), MockNavigationPlugin()],
            defaults: defaults,
            resetDefaults: false
        )
        thirdHost.selectPluginSettingsLandingPage()

        XCTAssertEqual(thirdHost.selectedFeatureSettingsPane, .featurePanelLayout)
    }

    private func makeHost(plugin: MockNavigationPlugin) -> PluginHost {
        makeHost(plugins: [plugin])
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        defaults: UserDefaults? = nil,
        resetDefaults: Bool = true
    ) -> PluginHost {
        let defaults = defaults ?? UserDefaults(suiteName: suiteName)!
        if resetDefaults {
            defaults.removePersistentDomain(forName: suiteName)
        }

        return PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }
}

@MainActor
private final class MockNavigationPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "mock-navigation",
        title: "Mock Navigation",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "Mock navigation plugin"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var receivedActions: [PluginPanelAction] = []

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Mock",
            isOn: false,
            isExpanded: true,
            isEnabled: true,
            isVisible: true,
            detail: PluginPanelDetail(primaryControls: [], secondaryPanel: nil),
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handleAction(_ action: PluginPanelAction) {
        receivedActions.append(action)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}

@MainActor
private final class MockDashboardNavigationPlugin: MacToolsPlugin, PluginComponentPanel {
    let metadata = PluginMetadata(
        id: "mock-dashboard-navigation",
        title: "Mock Dashboard Navigation",
        iconName: "rectangle.grid.2x2",
        iconTint: Color(nsColor: .systemPurple),
        order: 1,
        defaultDescription: "Mock dashboard navigation plugin"
    )

    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Mock",
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(EmptyView())
    }
}

@MainActor
private final class MockSettingsOnlyNavigationPlugin: MacToolsPlugin {
    let metadata = PluginMetadata(
        id: "mock-settings-only-navigation",
        title: "Mock Settings Only Navigation",
        iconName: "gearshape",
        iconTint: Color(nsColor: .systemGray),
        order: 1,
        defaultDescription: "Mock settings-only navigation plugin"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
}
