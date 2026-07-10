import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class FeatureManagementTableViewTests: XCTestCase {
    func testUpdatePolicySkipsUnchangedItems() {
        let items = [
            makeItem(id: "activity-bar", isVisible: true, isActive: false)
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
            makeItem(id: "activity-bar", isVisible: true, isActive: false)
        ]
        let currentItems = [
            makeItem(id: "activity-bar", isVisible: false, isActive: false)
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
            makeItem(id: "activity-bar", isVisible: true, isActive: false)
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
        let items = [makeItem(id: "activity-bar", isVisible: true, isActive: false)]

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

    func testSurfaceDescriptionsShowTheOtherVisibleSurface() {
        let item = makeItem(
            id: "activity-bar",
            isVisible: true,
            isActive: false,
            isVisibleOnOtherSurface: true
        )

        XCTAssertTrue(featureManagementDescription(for: item, mode: .surface(.dashboard)).contains(
            AppL10n.plugins(
                "plugin.management.alsoInFeaturePanel",
                defaultValue: "同时显示在功能面板"
            )
        ))
        XCTAssertTrue(featureManagementDescription(for: item, mode: .surface(.featurePanel)).contains(
            AppL10n.plugins(
                "plugin.management.alsoOnDashboard",
                defaultValue: "同时显示在仪表盘"
            )
        ))
    }

    func testDisabledSurfaceDescriptionSuppressesOtherSurfaceAndActiveIndicators() {
        let item = makeItem(
            id: "activity-bar",
            isVisible: true,
            isActive: true,
            isGloballyEnabled: false,
            isVisibleOnOtherSurface: true
        )
        let description = featureManagementDescription(for: item, mode: .surface(.dashboard))

        XCTAssertTrue(description.contains(
            AppL10n.plugins("plugin.management.disabled", defaultValue: "插件已停用")
        ))
        XCTAssertFalse(description.contains(
            AppL10n.plugins(
                "plugin.management.alsoInFeaturePanel",
                defaultValue: "同时显示在功能面板"
            )
        ))
        XCTAssertFalse(description.contains(
            AppL10n.plugins("plugin.management.active", defaultValue: "使用中")
        ))
    }

    func testToggleHelpMatchesInstalledAndSurfaceModes() {
        XCTAssertEqual(
            featureManagementToggleHelp(for: .installed),
            AppL10n.plugins("plugin.management.globalToggle", defaultValue: "启用或停用插件")
        )
        XCTAssertEqual(
            featureManagementToggleHelp(for: .surface(.dashboard)),
            AppL10n.plugins("plugin.management.dashboardToggle", defaultValue: "在仪表盘中显示")
        )
        XCTAssertEqual(
            featureManagementToggleHelp(for: .surface(.featurePanel)),
            AppL10n.plugins("plugin.management.featurePanelToggle", defaultValue: "在功能面板中显示")
        )
    }

    func testReorderPolicyRejectsInstalledAndFilteredModes() {
        let items = [
            makeItem(id: "first", isVisible: true, isActive: false),
            makeItem(id: "second", isVisible: true, isActive: false)
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
            makeItem(id: "visible-first", isVisible: true, isActive: false),
            makeItem(id: "visible-second", isVisible: true, isActive: false)
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

    private func makeItem(
        id: String,
        isVisible: Bool,
        isActive: Bool,
        isGloballyEnabled: Bool = true,
        isVisibleOnOtherSurface: Bool = true,
        capabilities: PluginHostCapabilities? = nil
    ) -> FeatureManagementTableItem {
        FeatureManagementTableItem(surfaceItem: PluginSurfaceLayoutItem(
            id: id,
            title: "活动统计",
            description: "统计输入与活动",
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            capabilities: capabilities ?? self.capabilities(dashboard: true, featurePanel: true),
            isGloballyEnabled: isGloballyEnabled,
            isVisible: isVisible,
            isVisibleOnOtherSurface: isVisibleOnOtherSurface,
            isActive: isActive,
            dashboardSpan: .oneByOne,
            category: nil,
            releaseChannel: nil
        ))
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

    func testInstalledModeHasNoDragHandleAndSurfaceModeSupportsReordering() {
        XCTAssertFalse(FeatureManagementTableMode.installed.supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.dashboard).supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.featurePanel).supportsReordering)
    }
}
