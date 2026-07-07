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
            previousIsReorderEnabled: true,
            currentIsReorderEnabled: true,
            previousContentWidth: 480,
            currentContentWidth: 482
        ))
    }

    private func makeItem(
        id: String,
        isVisible: Bool,
        isActive: Bool
    ) -> PluginFeatureManagementItem {
        PluginFeatureManagementItem(
            id: id,
            title: "活动统计",
            description: "统计输入与活动",
            iconName: "chart.bar.xaxis",
            iconTint: Color(nsColor: .systemGreen),
            isVisible: isVisible,
            isActive: isActive,
            presentation: .featureAndComponentPanel,
            category: nil,
            releaseChannel: nil
        )
    }
}
