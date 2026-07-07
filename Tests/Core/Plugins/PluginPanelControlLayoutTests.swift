import XCTest
import MacToolsPluginKit

final class PluginPanelControlLayoutTests: XCTestCase {
    func testControlKindTagsMatchDynamicPluginABI() {
        XCTAssertEqual(tag(of: PluginPanelControlKind.segmented), 0)
        XCTAssertEqual(tag(of: PluginPanelControlKind.datePicker), 1)
        XCTAssertEqual(tag(of: PluginPanelControlKind.selectList), 2)
        XCTAssertEqual(tag(of: PluginPanelControlKind.navigationList), 3)
        XCTAssertEqual(tag(of: PluginPanelControlKind.slider), 4)
        XCTAssertEqual(tag(of: PluginPanelControlKind.actionRow), 5)
        XCTAssertEqual(tag(of: PluginPanelControlKind.switchRow), 6)
    }

    func testStoredPropertyLayoutMatchesDynamicPluginABI() {
        let control = PluginPanelControl(
            id: "demo",
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: "Demo",
            actionIconSystemName: "hammer",
            isEnabled: true
        )

        XCTAssertEqual(
            Mirror(reflecting: control).children.compactMap(\.label),
            [
                "id",
                "kind",
                "options",
                "selectedOptionID",
                "dateValue",
                "minimumDate",
                "displayedComponents",
                "datePickerStyle",
                "sectionTitle",
                "sliderValue",
                "sliderBounds",
                "sliderStep",
                "valueLabel",
                "actionTitle",
                "actionIconSystemName",
                "actionBehavior",
                "showsLeadingDivider",
                "isEnabled",
            ]
        )
    }

    private func tag(of kind: PluginPanelControlKind) -> UInt8 {
        withUnsafeBytes(of: kind) { bytes in
            bytes[0]
        }
    }
}
