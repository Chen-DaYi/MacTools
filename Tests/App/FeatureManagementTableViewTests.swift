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
            makeItem(id: "activity-bar", isActive: false, canUninstall: true)
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

    func testUpdatePolicyRefreshesWhenVisibilityChanges() {
        let previousItems = [makeItem(id: "activity-bar", isActive: false, isVisible: true)]
        let currentItems = [makeItem(id: "activity-bar", isActive: false, isVisible: false)]

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

    func testUpdatePolicyRefreshesWhenSurfaceOrReorderAvailabilityChanges() {
        let items = [makeItem(id: "activity-bar", isActive: false)]

        XCTAssertTrue(FeatureManagementTableUpdatePolicy.needsUpdate(
            previousItems: items,
            currentItems: items,
            previousMode: .surface(.featurePanel),
            currentMode: .surface(.dashboard),
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
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

    func testVisibilityPresentationMatchesTheMetricRowConvention() {
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.symbolName(isVisible: true),
            "eye"
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.tintColor(isVisible: true),
            .systemBlue
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.symbolName(isVisible: false),
            "eye.slash"
        )
        XCTAssertEqual(
            FeatureManagementVisibilityPresentation.tintColor(isVisible: false),
            .tertiaryLabelColor
        )
    }

    func testRapidVisibilityActionsAlternateTheCellCachedValue() {
        var isVisible = true

        XCTAssertFalse(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
        XCTAssertTrue(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
        XCTAssertFalse(
            FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        )
    }

    func testReorderPolicyRejectsDisabledReordering() {
        let items = [
            makeItem(id: "first", isActive: false),
            makeItem(id: "second", isActive: false)
        ]

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

    @MainActor
    func testConfiguredLayoutCellHasOnlySettingsAndVisibilityActionButtons() {
        let item = makeItem(
            id: "beta-plugin",
            isActive: false,
            canUninstall: true,
            hasSettings: true
        )

        XCTAssertEqual(
            FeatureManagementTableCellInspection.inlineActionButtonCountAfterConfiguring(
                item: item,
                mode: .surface(.featurePanel),
                showsHandle: true
            ),
            2
        )
    }

    private func makeItem(
        id: String,
        isActive: Bool,
        isVisible: Bool = true,
        canUninstall: Bool = false,
        hasSettings: Bool = false,
        capabilities: PluginHostCapabilities? = nil,
        releaseChannel: String? = nil
    ) -> FeatureManagementTableItem {
        FeatureManagementTableItem(surfaceItem: makeSurfaceItem(
            id: id,
            isActive: isActive,
            isVisible: isVisible,
            canUninstall: canUninstall,
            capabilities: capabilities,
            releaseChannel: releaseChannel
        ), hasSettings: hasSettings)
    }

    private func makeSurfaceItem(
        id: String,
        isActive: Bool = false,
        isVisible: Bool = true,
        canUninstall: Bool = false,
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
            isVisible: isVisible,
            isActive: isActive,
            canUninstall: canUninstall,
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

    func testEveryLayoutSurfaceCanReorder() {
        XCTAssertTrue(FeatureManagementTableMode.surface(.dashboard).supportsReordering)
        XCTAssertTrue(FeatureManagementTableMode.surface(.featurePanel).supportsReordering)
        XCTAssertFalse(FeatureManagementReorderPolicy.canReorder(
            mode: .surface(.dashboard),
            isReorderEnabled: false
        ))
    }
}
