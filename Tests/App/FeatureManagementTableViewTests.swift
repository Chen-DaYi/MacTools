import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class FeatureManagementTableViewTests: XCTestCase {
    func testUpdatePolicySkipsUnchangedItems() {
        let items = [
            makeItem(id: "activity-bar", isActive: false)
        ]

        XCTAssertFalse(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480.2,
            currentContentWidth: 480.4
        ))
    }

    func testUpdatePolicyRefreshesWhenRowStateChanges() {
        let previousItems = [
            makeItem(id: "activity-bar", isActive: false)
        ]
        let currentItems = [
            makeItem(id: "activity-bar", isActive: false, isGloballyEnabled: false)
        ]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: previousItems,
            currentItems: currentItems,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 480
        ))
    }

    func testUpdatePolicyRefreshesWhenSettingsAvailabilityChanges() {
        let previousItems = [
            makeItem(id: "activity-bar", isActive: false, hasSettings: false)
        ]
        let currentItems = [
            makeItem(id: "activity-bar", isActive: false, hasSettings: true)
        ]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: previousItems,
            currentItems: currentItems,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 480
        ))
    }

    func testUpdatePolicyRefreshesWhenWidthChangesByPoint() {
        let items = [
            makeItem(id: "activity-bar", isActive: false)
        ]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 482
        ))
    }

    func testUpdatePolicyRefreshesWhenModeOrReorderAvailabilityChanges() {
        let items = [makeItem(id: "activity-bar", isActive: false)]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .installed,
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: false,
            currentIsReorderEnabled: false,
            previousContentWidth: 480,
            currentContentWidth: 480
        ))
        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .surface(.dashboard),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: false,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 480
        ))
    }

    func testCapabilitySummaryCoversEverySurfaceCombination() {
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: true, featurePanel: true)),
            AppL10n.plugins("plugin.capability.both", defaultValue: "仪表盘与功能面板")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: true, featurePanel: false)),
            AppL10n.plugins("plugin.capability.dashboard", defaultValue: "仪表盘")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: false, featurePanel: true)),
            AppL10n.plugins("plugin.capability.featurePanel", defaultValue: "功能面板")
        )
        XCTAssertEqual(
            pluginCapabilitySummary(capabilities(dashboard: false, featurePanel: false)),
            AppL10n.plugins("plugin.capability.settingsOnly", defaultValue: "仅设置")
        )
    }

    func testSurfaceDescriptionsStayFocusedOnLayout() {
        let item = makeItem(
            id: "activity-bar",
            isActive: false
        )

        XCTAssertEqual(
            featureManagementDescription(for: item, mode: .surface(.dashboard)),
            item.description
        )
        XCTAssertEqual(
            featureManagementDescription(for: item, mode: .surface(.featurePanel)),
            item.description
        )
    }

    func testSurfaceLayoutSeparatesGloballyDisabledPlugins() {
        let items = [
            makeSurfaceItem(id: "enabled", isGloballyEnabled: true),
            makeSurfaceItem(id: "disabled", isGloballyEnabled: false),
            makeSurfaceItem(id: "enabled-second", isGloballyEnabled: true)
        ]

        XCTAssertEqual(
            PluginSurfaceLayoutDisplayPolicy.enabledItems(from: items).map(\.id),
            ["enabled", "enabled-second"]
        )
        XCTAssertEqual(
            PluginSurfaceLayoutDisplayPolicy.disabledItems(from: items).map(\.id),
            ["disabled"]
        )
        XCTAssertEqual(PluginSurfaceLayoutDisplayPolicy.disabledItemCount(in: items), 1)
    }

    func testControlHelpMatchesInstalledAndSurfaceModes() {
        XCTAssertEqual(
            featureManagementControlHelp(for: .installed),
            AppL10n.plugins("plugin.management.globalToggle", defaultValue: "启用或停用插件")
        )
        XCTAssertEqual(
            featureManagementControlHelp(for: .surface(.dashboard)),
            AppL10n.plugins("plugin.management.globalToggle", defaultValue: "启用或停用插件")
        )
        XCTAssertEqual(
            featureManagementControlHelp(for: .surface(.featurePanel)),
            AppL10n.plugins("plugin.management.globalToggle", defaultValue: "启用或停用插件")
        )
    }

    func testReorderPolicyRejectsInstalledAndFilteredModes() {
        let items = [
            makeItem(id: "first", isActive: false),
            makeItem(id: "second", isActive: false)
        ]

        XCTAssertNil(FeatureManagementReorderPolicy.targetOffset(
            for: "first",
            proposedRow: 1,
            items: items,
            mode: .installed,
            isReorderEnabled: true
        ))
        XCTAssertNil(FeatureManagementReorderPolicy.targetOffset(
            for: "first",
            proposedRow: 1,
            items: items,
            mode: .surface(.dashboard),
            isReorderEnabled: false
        ))
    }

    func testReorderPolicyUsesSurfaceLocalRowsAndClampsOffsets() {
        let surfaceItems = [
            makeItem(id: "visible-first", isActive: false),
            makeItem(id: "visible-second", isActive: false)
        ]

        XCTAssertEqual(FeatureManagementReorderPolicy.targetOffset(
            for: "visible-first",
            proposedRow: -4,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ), 0)
        XCTAssertEqual(FeatureManagementReorderPolicy.targetOffset(
            for: "visible-first",
            proposedRow: 20,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ), surfaceItems.count)
        XCTAssertNil(FeatureManagementReorderPolicy.targetOffset(
            for: "not-on-surface",
            proposedRow: 1,
            items: surfaceItems,
            mode: .surface(.dashboard),
            isReorderEnabled: true
        ))
    }

    @MainActor
    func testConfiguredTableCellDoesNotEmbedSwiftUIHostingViews() {
        let item = makeItem(
            id: "beta-plugin",
            isActive: true,
            hasSettings: true,
            releaseChannel: "beta"
        )

        XCTAssertFalse(FeatureManagementTableCellInspection.containsSwiftUIHostingViewAfterConfiguring(
            item: item,
            mode: .surface(.featurePanel),
            showsHandle: true
        ))
    }

    private func makeItem(
        id: String,
        isActive: Bool,
        isGloballyEnabled: Bool = true,
        hasSettings: Bool = false,
        capabilities: PluginHostCapabilities? = nil,
        releaseChannel: String? = nil
    ) -> FeatureManagementTableItem {
        FeatureManagementTableItem(surfaceItem: makeSurfaceItem(
            id: id,
            isActive: isActive,
            isGloballyEnabled: isGloballyEnabled,
            capabilities: capabilities,
            releaseChannel: releaseChannel
        ), hasSettings: hasSettings)
    }

    private func makeSurfaceItem(
        id: String,
        isActive: Bool = false,
        isGloballyEnabled: Bool,
        capabilities: PluginHostCapabilities? = nil,
        releaseChannel: String? = nil
    ) -> PluginSurfaceLayoutItem {
        PluginSurfaceLayoutItem(
            id: id,
            title: "活动统计",
            description: "统计输入与活动",
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            capabilities: capabilities ?? self.capabilities(dashboard: true, featurePanel: true),
            isGloballyEnabled: isGloballyEnabled,
            isActive: isActive,
            dashboardSpan: .oneByOne,
            category: nil,
            releaseChannel: releaseChannel
        )
    }

    private func capabilities(
        dashboard: Bool,
        featurePanel: Bool
    ) -> PluginHostCapabilities {
        PluginHostCapabilities(
            supportsDashboard: dashboard,
            supportsFeaturePanel: featurePanel,
            hasCustomConfiguration: false
        )
    }

    func testEveryModeUsesGlobalEnablementAndOnlySurfaceRowsCanReorder() {
        XCTAssertFalse(FeatureManagementTableMode.installed.supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.dashboard).supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.featurePanel).supportsReordering)
        XCTAssertFalse(FeatureManagementReorderPolicy.canReorder(
            mode: .surface(.dashboard),
            isReorderEnabled: false
        ))
    }
}
