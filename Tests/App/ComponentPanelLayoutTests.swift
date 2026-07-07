import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class ComponentPanelLayoutTests: XCTestCase {
    func testComponentCardCornerRadiusMatchesLeftClickPanelCornerRadius() {
        XCTAssertEqual(
            PluginComponentPanelLayoutMetrics.cardCornerRadius,
            MenuBarPanelLayout.cornerRadius
        )
    }

    func testPanelWidthUsesFourFixedColumnsWithinExistingPanelWidth() {
        XCTAssertEqual(ComponentPanelLayout.columns, 4)
        XCTAssertEqual(ComponentPanelLayout.cellWidth, 70)
        XCTAssertEqual(ComponentPanelLayout.originalCellHeight, 94)
        XCTAssertEqual(ComponentPanelLayout.cellHeight, 8)
        XCTAssertEqual(ComponentPanelLayout.horizontalSpacing, 8)
        XCTAssertEqual(ComponentPanelLayout.verticalSpacing, 6)
        XCTAssertEqual(ComponentPanelLayout.verticalSpacing, ComponentPanelLayout.horizontalPadding)
        XCTAssertEqual(ComponentPanelLayout.horizontalPadding, MenuBarPanelLayout.outerPadding)
        XCTAssertEqual(ComponentPanelLayout.topPadding, MenuBarPanelLayout.contentTopPadding)
        XCTAssertEqual(ComponentPanelLayout.bottomPadding, MenuBarPanelLayout.contentBottomPadding)
        XCTAssertEqual(ComponentPanelLayout.verticalPadding, MenuBarPanelLayout.outerPadding)
        XCTAssertEqual(ComponentPanelLayout.contentVerticalPadding, 10)
        XCTAssertEqual(
            ComponentPanelLayout.panelWidth,
            ComponentPanelLayout.horizontalPadding * 2
                + ComponentPanelLayout.cellWidth * 4
                + ComponentPanelLayout.horizontalSpacing * 3
        )
        XCTAssertEqual(ComponentPanelLayout.panelWidth, 316)
    }

    func testScrollClipCornerRadiusMatchesPanelCornerRadius() {
        XCTAssertEqual(
            ComponentPanelLayout.scrollClipCornerRadius,
            MenuBarPanelLayout.cornerRadius
        )
    }

    func testGridUsesCompactRowsForDenseComponents() {
        XCTAssertLessThan(ComponentPanelLayout.cellHeight, ComponentPanelLayout.cellWidth)
        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: .oneByOne), ComponentPanelLayout.cellHeight)
        XCTAssertEqual(
            ComponentPanelLayout.yOffset(for: ComponentGridPlacement(
                id: "a",
                row: 1,
                column: 0,
                span: .oneByOne,
                yOffset: ComponentPanelLayout.cellHeight + ComponentPanelLayout.verticalSpacing
            )),
            ComponentPanelLayout.cellHeight + ComponentPanelLayout.verticalSpacing
        )
    }

    func testExpandedSpansUseCompactRowHeightAndExternalSpacing() throws {
        let oneOriginalRow = try XCTUnwrap(PluginComponentSpan(width: 4, height: 12))
        let twoOriginalRows = try XCTUnwrap(PluginComponentSpan(width: 4, height: 25))
        let threeOriginalRows = try XCTUnwrap(PluginComponentSpan(width: 4, height: 37))

        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: oneOriginalRow), 96)
        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: twoOriginalRows), 200)
        XCTAssertEqual(ComponentPanelLayout.itemHeight(for: threeOriginalRows), 296)

        let nextAfterOneCompactRow = ComponentGridPlacement(
            id: "after-compact",
            row: 1,
            column: 0,
            span: .oneByOne,
            yOffset: ComponentPanelLayout.cellHeight + ComponentPanelLayout.verticalSpacing
        )
        let nextAfterOneOriginalRow = ComponentGridPlacement(
            id: "after-original",
            row: 12,
            column: 0,
            span: .oneByOne,
            yOffset: ComponentPanelLayout.itemHeight(for: oneOriginalRow) + ComponentPanelLayout.verticalSpacing
        )
        XCTAssertEqual(
            ComponentPanelLayout.yOffset(for: nextAfterOneCompactRow) - ComponentPanelLayout.itemHeight(for: .oneByOne),
            ComponentPanelLayout.verticalSpacing
        )
        XCTAssertEqual(
            ComponentPanelLayout.yOffset(for: nextAfterOneOriginalRow) - ComponentPanelLayout.itemHeight(for: oneOriginalRow),
            ComponentPanelLayout.verticalSpacing
        )
    }

    func testPreferredHeightForItemsIncludesSharedToolbarAndVerticalPadding() {
        let item = makeItem(id: "system", span: .fourByTwo)

        XCTAssertEqual(
            ComponentPanelLayout.preferredContentHeight(for: [item], screen: nil),
            ComponentPanelLayout.itemHeight(for: .fourByTwo) + ComponentPanelLayout.contentVerticalPadding
        )
        XCTAssertEqual(
            ComponentPanelLayout.preferredPanelHeight(for: [item], screen: nil),
            MenuBarPanelLayout.topChromeHeight
                + ComponentPanelLayout.itemHeight(for: .fourByTwo)
                + ComponentPanelLayout.contentVerticalPadding
        )
    }

    func testFirstFitPlacesMixedSpansDeterministically() {
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "a", span: .oneByOne),
                makeItem(id: "b", span: .oneByTwo),
                makeItem(id: "c", span: .twoByTwo)
            ]
        )

        XCTAssertEqual(
            placements,
            [
                ComponentGridPlacement(id: "a", row: 0, column: 0, span: .oneByOne, yOffset: 0),
                ComponentGridPlacement(id: "b", row: 0, column: 1, span: .oneByTwo, yOffset: 0),
                ComponentGridPlacement(id: "c", row: 0, column: 2, span: .twoByTwo, yOffset: 0)
            ]
        )
    }

    func testWideSpansOccupyFourColumnGridAndAllowLaterSingleColumnFill() {
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "wide", span: .fourByTwo),
                makeItem(id: "left", span: .oneByOne),
                makeItem(id: "right", span: .twoByOne)
            ]
        )

        XCTAssertEqual(
            placements,
            [
                ComponentGridPlacement(id: "wide", row: 0, column: 0, span: .fourByTwo, yOffset: 0),
                ComponentGridPlacement(id: "left", row: 2, column: 0, span: .oneByOne, yOffset: 22),
                ComponentGridPlacement(id: "right", row: 2, column: 1, span: .twoByOne, yOffset: 22)
            ]
        )
    }

    func testStackedCardsHaveOnlyInterCardSpacingAndNoTrailingGap() throws {
        let firstSpan = try XCTUnwrap(PluginComponentSpan(width: 4, height: 12))
        let secondSpan = try XCTUnwrap(PluginComponentSpan(width: 4, height: 25))
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "first", span: firstSpan),
                makeItem(id: "second", span: secondSpan)
            ]
        )

        XCTAssertEqual(placements.map(\.yOffset), [0, 102])
        XCTAssertEqual(ComponentPanelLayout.gridContentHeight(for: placements), 302)
    }

    func testColumnStackingUsesOnlyInterCardSpacingForMixedWidths() {
        let placements = ComponentGridPlacementEngine.placements(
            for: [
                makeItem(id: "left-tall", span: .oneByTwo),
                makeItem(id: "right-short", span: .oneByOne),
                makeItem(id: "left-next", span: .oneByOne)
            ]
        )

        XCTAssertEqual(
            placements,
            [
                ComponentGridPlacement(id: "left-tall", row: 0, column: 0, span: .oneByTwo, yOffset: 0),
                ComponentGridPlacement(id: "right-short", row: 0, column: 1, span: .oneByOne, yOffset: 0),
                ComponentGridPlacement(id: "left-next", row: 0, column: 2, span: .oneByOne, yOffset: 0)
            ]
        )
        XCTAssertEqual(ComponentPanelLayout.gridContentHeight(for: placements), 16)
    }

    func testEmptyLayoutUsesEmptyStateHeight() {
        XCTAssertEqual(
            ComponentPanelLayout.gridContentHeight(for: []),
            ComponentPanelLayout.emptyContentHeight
        )
        XCTAssertGreaterThanOrEqual(
            ComponentPanelLayout.preferredPanelHeight(for: [], screen: nil),
            ComponentPanelLayout.minimumPanelHeight
        )
    }

    private func makeItem(id: String, span: PluginComponentSpan) -> PluginComponentItem {
        PluginComponentItem(
            id: id,
            title: id,
            iconName: "sparkles",
            iconTint: Color(nsColor: .systemBlue),
            description: id,
            helpText: id,
            descriptionTone: .secondary,
            span: span,
            isActive: false,
            isEnabled: true
        )
    }
}
