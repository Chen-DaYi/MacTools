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

    func testShortcutSettingsItemStoredPropertyLayoutMatchesPluginKitV3ABI() {
        let item = ShortcutSettingsItem(
            id: "demo",
            pluginID: "plugin",
            pluginTitle: "Plugin",
            title: "Shortcut",
            description: "Description",
            bindingText: "⌘A",
            isRequired: false,
            canClear: true,
            usesDefaultValue: false,
            errorMessage: nil
        )

        XCTAssertEqual(
            Mirror(reflecting: item).children.compactMap(\.label),
            [
                "id", "pluginID", "pluginTitle", "title", "description",
                "bindingText", "isRequired", "canClear", "usesDefaultValue",
                "errorMessage", "settingsGroupID", "settingsGroupTitle",
                "settingsGroupDescription", "settingsControlTitle",
                "settingsControlSystemImage",
            ]
        )
    }

    @MainActor
    func testShortcutRecorderStoredPropertyLayoutMatchesPluginKitV3ABI() {
        let recorder = PluginShortcutRecorder(
            title: "Shortcut",
            displayText: "⌘A",
            onRecord: { _ in .accepted }
        )

        XCTAssertEqual(
            Mirror(reflecting: recorder).children.compactMap(\.label),
            [
                "title", "displayText", "placeholder", "minWidth", "onRecord",
                "onBeginRecording", "onEndRecording", "_isPresented",
            ]
        )
    }

    func testShortcutRecordingResultKeepsThePluginKitV3Cases() {
        func label(_ result: PluginShortcutRecordingResult) -> String {
            switch result {
            case .accepted: "accepted"
            case .rejected: "rejected"
            }
        }

        XCTAssertEqual(label(.accepted), "accepted")
        XCTAssertEqual(label(.rejected("conflict")), "rejected")
    }

    private func tag(of kind: PluginPanelControlKind) -> UInt8 {
        withUnsafeBytes(of: kind) { bytes in
            bytes[0]
        }
    }
}
