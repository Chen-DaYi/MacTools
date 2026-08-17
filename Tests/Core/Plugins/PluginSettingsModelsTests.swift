import SwiftUI
import XCTest
import MacToolsPluginKit

final class PluginSettingsModelsTests: XCTestCase {
    func testValidatorAcceptsDeclarativeRowsAndPlacedShortcutGroup() throws {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "behavior",
                    rows: [
                        PluginSettingsRow(
                            id: "mode",
                            title: "模式",
                            control: .picker(
                                selectionID: "automatic",
                                options: [
                                    PluginSettingsOption(id: "automatic", title: "自动"),
                                    PluginSettingsOption(id: "manual", title: "手动")
                                ],
                                style: .menu
                            )
                        ),
                        PluginSettingsRow(
                            id: "visible-mode",
                            title: "显示模式",
                            control: .choiceGroup(
                                selectionID: "automatic",
                                options: [
                                    PluginSettingsOption(id: "automatic", title: "自动"),
                                    PluginSettingsOption(id: "manual", title: "手动")
                                ]
                            )
                        ),
                        PluginSettingsRow(
                            id: "level",
                            title: "级别",
                            control: .slider(
                                value: 50,
                                range: 0...100,
                                step: 1,
                                valueFormat: .percentage
                            )
                        )
                    ]
                ),
                .shortcutGroup("devices", title: "设备快捷键")
            ]
        )

        XCTAssertNoThrow(
            try PluginSettingsValidator.validate(
                page,
                availableShortcutGroupIDs: ["devices"]
            )
        )
    }

    func testValidatorRejectsDuplicateStableIDs() {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "first",
                    rows: [row(id: "duplicate")]
                ),
                PluginSettingsSection(
                    id: "second",
                    rows: [row(id: "duplicate")]
                )
            ]
        )

        XCTAssertThrowsError(try PluginSettingsValidator.validate(page)) { error in
            XCTAssertEqual(error as? PluginSettingsValidationError, .duplicateRowID("duplicate"))
        }
    }

    func testValidatorRejectsInvalidPickerSelectionAndSlider() {
        let missingSelection = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "picker",
                    rows: [
                        PluginSettingsRow(
                            id: "mode",
                            title: "模式",
                            control: .picker(
                                selectionID: "missing",
                                options: [PluginSettingsOption(id: "automatic", title: "自动")],
                                style: .automatic
                            )
                        )
                    ]
                )
            ]
        )
        let invalidSlider = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "slider",
                    rows: [
                        PluginSettingsRow(
                            id: "level",
                            title: "级别",
                            control: .slider(
                                value: 101,
                                range: 0...100,
                                step: 0,
                                valueFormat: nil
                            )
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try PluginSettingsValidator.validate(missingSelection)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .missingPickerSelection(rowID: "mode", selectionID: "missing")
            )
        }
        XCTAssertThrowsError(try PluginSettingsValidator.validate(invalidSlider)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .sliderValueOutOfRange(rowID: "level")
            )
        }
    }

    func testSliderFormattingAndSnappingStayIndependentOfPageRebuilds() throws {
        let format = PluginSettingsSliderValueFormat(
            prefix: "",
            suffix: "%",
            fractionDigits: 0
        )

        XCTAssertEqual(
            format.text(for: 79.6, locale: Locale(identifier: "en_US_POSIX")),
            "80%"
        )
        XCTAssertEqual(
            PluginSettingsSlider.snappedValue(79.6, in: 20...100, step: 1),
            80
        )
        XCTAssertEqual(
            PluginSettingsSlider.snappedValue(50, in: 48...96, step: 4),
            52
        )
    }

    func testValidatorRejectsInvalidSliderValueFormat() {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "slider",
                    rows: [
                        PluginSettingsRow(
                            id: "level",
                            title: "级别",
                            control: .slider(
                                value: 50,
                                range: 0...100,
                                step: 1,
                                valueFormat: PluginSettingsSliderValueFormat(
                                    fractionDigits: 13
                                )
                            )
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try PluginSettingsValidator.validate(page)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .invalidSliderValueFormat(rowID: "level")
            )
        }
    }

    func testValidatorRejectsMissingOrDuplicatedEmbeddedShortcutGroups() {
        let page = PluginSettingsPage.form(
            sections: [
                PluginSettingsSection(
                    id: "custom",
                    embeddedShortcutGroupIDs: ["devices"]
                ) { _ in
                    EmptyView()
                },
                .shortcutGroup("devices")
            ]
        )

        XCTAssertThrowsError(
            try PluginSettingsValidator.validate(
                page,
                availableShortcutGroupIDs: ["devices"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .duplicateShortcutGroupID("devices")
            )
        }

        let missing = PluginSettingsPage.form(sections: [.shortcutGroup("missing")])
        XCTAssertThrowsError(try PluginSettingsValidator.validate(missing)) { error in
            XCTAssertEqual(
                error as? PluginSettingsValidationError,
                .missingShortcutGroup("missing")
            )
        }
    }

    func testCustomSectionKeepsHostPresentationAndBuildsAccessoryLazily() {
        var accessoryBuildCount = 0
        let section = PluginSettingsSection(
            id: "devices",
            title: "设备",
            presentation: .edgeToEdge,
            isVisible: false
        ) { _ in
            EmptyView()
        }
        .headerAccessory { _ in
            accessoryBuildCount += 1
            return Button("刷新") {}
        }

        XCTAssertFalse(section.isVisible)
        if case .edgeToEdge = section.presentation {
            // Expected.
        } else {
            XCTFail("Custom table section should preserve edge-to-edge presentation")
        }
        XCTAssertEqual(accessoryBuildCount, 0)

        _ = section.headerAccessory?.makeView(PluginSettingsContext(pluginID: "test"))
        XCTAssertEqual(accessoryBuildCount, 1)
    }

    func testWorkspaceDeclaresScrollOwnership() {
        let hostScrollingPage = PluginSettingsPage.workspace(scrolling: .host) { _ in
            EmptyView()
        }
        let selfManagedPage = PluginSettingsPage.workspace { _ in
            EmptyView()
        }

        guard case let .workspace(hostWorkspace) = hostScrollingPage.body,
              case let .workspace(selfManagedWorkspace) = selfManagedPage.body
        else {
            return XCTFail("Expected workspace pages")
        }

        if case .host = hostWorkspace.scrolling {
            // Expected.
        } else {
            XCTFail("Host-scrolling workspace lost its scroll policy")
        }
        if case .selfManaged = selfManagedWorkspace.scrolling {
            // Expected.
        } else {
            XCTFail("Workspace should default to self-managed scrolling")
        }
    }

    func testPageVisibilityAndHiddenShortcutPlacementRemainPageLevel() {
        var visibilityChanges: [Bool] = []
        let page = PluginSettingsPage.form(
            sections: [
                .shortcutGroup("visible"),
                PluginSettingsSection(
                    id: "hidden",
                    isVisible: false,
                    embeddedShortcutGroupIDs: ["hidden"]
                ) { _ in
                    EmptyView()
                }
            ]
        )
        .onVisibilityChange { visibilityChanges.append($0) }

        page.visibilityHandler?(true)
        page.visibilityHandler?(false)

        XCTAssertEqual(visibilityChanges, [true, false])
        XCTAssertEqual(page.body.integratedShortcutGroupIDs, ["visible"])
    }

    private func row(id: String) -> PluginSettingsRow {
        PluginSettingsRow(id: id, title: id, control: .toggle(isOn: false))
    }

}
