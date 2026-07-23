import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class MenuBarPanelLayoutTests: XCTestCase {
    func testSecondaryPanelPlacementPrefersRightWhenItFits() {
        let placement = SecondaryPanelPlacement.resolve(
            anchorRect: CGRect(x: 100, y: 500, width: 280, height: 52),
            panelSize: CGSize(width: 216, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        guard case let .right(frame) = placement else {
            return XCTFail("Expected a right-side secondary panel")
        }

        XCTAssertEqual(frame.origin.x, 390)
        XCTAssertEqual(frame.origin.y, 252)
    }

    func testSecondaryPanelPlacementFallsBackToLeftWhenRightDoesNotFit() {
        let placement = SecondaryPanelPlacement.resolve(
            anchorRect: CGRect(x: 1_150, y: 500, width: 200, height: 52),
            panelSize: CGSize(width: 216, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        guard case let .left(frame) = placement else {
            return XCTFail("Expected a left-side secondary panel")
        }

        XCTAssertEqual(frame.origin.x, 924)
        XCTAssertEqual(frame.origin.y, 252)
    }

    func testSecondaryPanelPlacementUsesInlineFallbackWhenNeitherSideFits() {
        let placement = SecondaryPanelPlacement.resolve(
            anchorRect: CGRect(x: 82, y: 500, width: 316, height: 52),
            panelSize: CGSize(width: 216, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 470, height: 900)
        )

        XCTAssertEqual(placement, .inline)
    }

    func testSecondaryPanelPlacementKeepsPanelWithinVerticalScreenBounds() {
        let placement = SecondaryPanelPlacement.resolve(
            anchorRect: CGRect(x: 100, y: 100, width: 200, height: 52),
            panelSize: CGSize(width: 216, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        guard case let .right(frame) = placement else {
            return XCTFail("Expected a right-side secondary panel")
        }

        XCTAssertEqual(frame.minY, MenuBarPanelLayout.secondaryPanelScreenMargin)
    }

    func testBaseLayoutMetricsStayStable() {
        XCTAssertEqual(MenuBarPanelLayout.baseWidth, 316)
        XCTAssertEqual(
            MenuBarPanelLayout.surfaceWidth,
            MenuBarPanelLayout.baseWidth - (MenuBarPanelLayout.outerPadding * 2)
        )
        XCTAssertEqual(MenuBarPanelLayout.topChromeHeight, 36)
        XCTAssertEqual(MenuBarPanelLayout.contentTopPadding, 4)
        XCTAssertEqual(MenuBarPanelLayout.contentBottomPadding, 6)
        XCTAssertEqual(MenuBarPanelLayout.contentVerticalPadding, 10)
        XCTAssertEqual(
            MenuBarPanelLayout.contentBodyHeight(forContentHeight: 184),
            174
        )
        XCTAssertEqual(MenuBarPanelLayout.minimumContentHeight, 184)
        XCTAssertEqual(MenuBarPanelLayout.rowHeaderHeight, 31)
    }

    func testContentSizeUsesModelWithoutSwiftUILayoutMeasurement() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: true,
            controls: [
                PluginPanelControl(
                    id: "display-navigation",
                    kind: .navigationList,
                    options: [
                        PluginPanelControlOption(id: "1", title: "Studio Display"),
                        PluginPanelControlOption(id: "2", title: "LG UltraFine")
                    ],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.contentSize(for: [item]),
            NSSize(width: 316, height: 220)
        )
    }

    func testDisclosureDetailHeightIncludesSwitchRows() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: true,
            controls: [
                PluginPanelControl(
                    id: "tracking-enabled",
                    kind: .switchRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: "活动统计",
                    actionIconSystemName: "chart.bar.xaxis",
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.contentSize(for: [item]),
            NSSize(width: 316, height: 220)
        )
    }

    func testExpandedFeatureContentHeightIncludesFullHeaderTextHeight() {
        let expandedItem = makeItem(
            controlStyle: .disclosure,
            isExpanded: true,
            controls: [
                PluginPanelControl(
                    id: "brightness",
                    kind: .slider,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: "亮度",
                    sliderValue: 0.7,
                    sliderBounds: 0...1,
                    valueLabel: "70%",
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.featureContentHeight(for: [expandedItem]),
            MenuBarPanelLayout.rowHeaderHeight
                + MenuBarPanelLayout.detailSpacing
                + 15
                + 6
                + 18
                + MenuBarPanelLayout.sliderVerticalPadding * 2
                + MenuBarPanelLayout.rowVerticalPadding
        )
    }

    func testSwitchFeatureContentHeightIncludesDisplayedDetail() {
        let item = makeItem(
            controlStyle: .switch,
            isExpanded: false,
            controls: [
                PluginPanelControl(
                    id: "duration",
                    kind: .segmented,
                    options: [
                        PluginPanelControlOption(id: "forever", title: "永不"),
                        PluginPanelControlOption(id: "thirty-minutes", title: "30min")
                    ],
                    selectedOptionID: "forever",
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.featureContentHeight(for: [item]),
            MenuBarPanelLayout.rowHeaderHeight
                + MenuBarPanelLayout.detailSpacing
                + 24
                + MenuBarPanelLayout.rowVerticalPadding
        )
    }

    func testButtonFeatureContentHeightIncludesDisplayedDetail() {
        let item = makeItem(
            controlStyle: .button,
            isExpanded: false,
            controls: [
                PluginPanelControl(
                    id: "open-details",
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: "打开详情",
                    actionIconSystemName: "arrow.up.right.square",
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.featureContentHeight(for: [item]),
            MenuBarPanelLayout.rowHeaderHeight
                + MenuBarPanelLayout.detailSpacing
                + 16
                + MenuBarPanelLayout.actionRowVerticalPadding * 2
                + MenuBarPanelLayout.rowVerticalPadding
        )
    }

    func testActionRowFeatureContentHeightIncludesSectionTitle() {
        let item = makeItem(
            controlStyle: .button,
            isExpanded: false,
            controls: [
                PluginPanelControl(
                    id: "wired-only",
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: "仅有线：不会回退到 Wi-Fi",
                    actionTitle: "仅通过有线连接",
                    actionIconSystemName: "cable.connector",
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.featureContentHeight(for: [item]),
            MenuBarPanelLayout.rowHeaderHeight
                + MenuBarPanelLayout.detailSpacing
                + MenuBarPanelLayout.actionRowSectionTitleHeight
                + MenuBarPanelLayout.actionRowSectionTitleSpacing
                + 16
                + MenuBarPanelLayout.actionRowVerticalPadding * 2
                + MenuBarPanelLayout.rowVerticalPadding
        )
    }

    func testCollapsedDisclosureFeatureContentHeightIgnoresDetail() {
        let item = makeItem(
            controlStyle: .disclosure,
            isExpanded: false,
            controls: [
                PluginPanelControl(
                    id: "brightness",
                    kind: .slider,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: "亮度",
                    sliderValue: 0.7,
                    sliderBounds: 0...1,
                    valueLabel: "70%",
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            MenuBarPanelLayout.featureContentHeight(for: [item]),
            MenuBarPanelLayout.rowHeaderHeight
                + MenuBarPanelLayout.rowVerticalPadding
        )
    }

    func testPreferredPanelHeightCapsTallFeatureLists() {
        let items = (0..<40).map { index in
            makeItem(id: "plugin-\(index)", controlStyle: .switch, isExpanded: false)
        }

        XCTAssertEqual(
            MenuBarPanelLayout.preferredPanelHeight(for: items, screen: nil),
            MenuBarPanelLayout.featureListMaximumHeight
                + MenuBarPanelLayout.contentVerticalPadding
                + MenuBarPanelLayout.topChromeHeight
        )
        XCTAssertEqual(MenuBarPanelLayout.maximumPanelHeight(visibleFrameHeight: 1000), 750)
    }

    func testEmptyContentSizeIncludesMarketplacePrompt() {
        XCTAssertEqual(
            MenuBarPanelLayout.contentSize(for: []),
            NSSize(width: 316, height: 220)
        )
    }

    private func makeItem(
        id: String = "display-resolution",
        controlStyle: PluginControlStyle,
        isExpanded: Bool,
        controls: [PluginPanelControl] = []
    ) -> PluginPanelItem {
        PluginPanelItem(
            id: id,
            title: "显示器分辨率",
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            controlStyle: controlStyle,
            menuActionBehavior: .keepPresented,
            description: "查看并切换每个显示器的分辨率",
            helpText: "查看并切换每个显示器的分辨率",
            descriptionTone: .secondary,
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            detail: PluginPanelDetail(primaryControls: controls, secondaryPanel: nil),
            buttonActionID: nil,
            buttonTitle: nil
        )
    }
}

@MainActor
final class HoverSecondaryPanelCoordinatorTests: XCTestCase {
    func testSwitchingActivationClearsPreviousAnchor() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let firstActivation = makeActivation(optionID: "2")
        let secondActivation = makeActivation(optionID: "3")

        coordinator.hoverBegan(
            pluginID: firstActivation.pluginID,
            controlID: firstActivation.controlID,
            optionID: firstActivation.optionID
        )
        coordinator.updateRowFrame(
            CGRect(x: 10, y: 20, width: 30, height: 40),
            for: firstActivation
        )
        coordinator.hoverBegan(
            pluginID: secondActivation.pluginID,
            controlID: secondActivation.controlID,
            optionID: secondActivation.optionID
        )

        XCTAssertEqual(coordinator.activeActivation, secondActivation)
        XCTAssertNil(coordinator.selectedRowFrame)
    }

    func testHoverBeganUsesCachedFrameForNewActivation() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let activation = makeActivation(optionID: "3")
        let frame = CGRect(x: 30, y: 40, width: 120, height: 48)

        coordinator.updateRowFrame(frame, for: activation)
        coordinator.hoverBegan(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )

        XCTAssertEqual(coordinator.activeActivation, activation)
        XCTAssertEqual(coordinator.selectedRowFrame, frame)
    }

    func testPinnedActivationSurvivesHoverExit() async {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let activation = makeActivation(optionID: "3")
        var dismissedActivation: HoverSecondaryPanelCoordinator.Activation?
        coordinator.onDismissRequest = { dismissedActivation = $0 }

        coordinator.pin(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.hoverEnded(
            pluginID: activation.pluginID,
            controlID: activation.controlID,
            optionID: activation.optionID
        )
        coordinator.setPanelHovered(false)
        try? await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(coordinator.activeActivation, activation)
        XCTAssertNil(dismissedActivation)
    }

    func testPinnedActivationIgnoresHoverPreviewFromOtherRows() {
        let coordinator = HoverSecondaryPanelCoordinator(
            dismissDelay: .milliseconds(5),
            activationDelay: nil
        )
        let pinnedActivation = makeActivation(optionID: "3")
        let previewActivation = makeActivation(optionID: "4")

        coordinator.pin(
            pluginID: pinnedActivation.pluginID,
            controlID: pinnedActivation.controlID,
            optionID: pinnedActivation.optionID
        )
        coordinator.hoverBegan(
            pluginID: previewActivation.pluginID,
            controlID: previewActivation.controlID,
            optionID: previewActivation.optionID
        )

        XCTAssertEqual(coordinator.activeActivation, pinnedActivation)
    }

    private func makeActivation(optionID: String) -> HoverSecondaryPanelCoordinator.Activation {
        HoverSecondaryPanelCoordinator.Activation(
            pluginID: "display-resolution",
            controlID: "display-navigation",
            optionID: optionID
        )
    }
}
