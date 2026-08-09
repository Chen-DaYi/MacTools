import AppKit
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

    @MainActor
    func testStandardCardSurfaceSeparatesFromWindowInBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: PluginSettingsCardSurfaceProbe())
            host.frame = NSRect(x: 0, y: 0, width: 220, height: 140)
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)

            let pageColor = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10))
            let cardColor = try XCTUnwrap(bitmap.colorAt(x: 110, y: 70))
            let contrast = abs(Self.relativeLuminance(cardColor) - Self.relativeLuminance(pageColor))

            XCTAssertGreaterThan(
                contrast,
                0.008,
                "Standard cards must remain visually distinct in \(appearanceName.rawValue)"
            )
            XCTAssertLessThan(
                contrast,
                0.08,
                "Standard cards should preserve the subtle grouped-Form hierarchy"
            )
        }
    }

    @MainActor
    func testShortcutControlLayoutKeepsRecorderAdjacentToLabel() throws {
        let host = NSHostingView(rootView: PluginSettingsShortcutLayoutProbe())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        var labelPixels: [Int] = []
        var recorderPixels: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > color.greenComponent + 0.3,
                   color.redComponent > color.blueComponent + 0.3 {
                    labelPixels.append(x)
                }
                if color.blueComponent > color.redComponent + 0.3,
                   color.blueComponent > color.greenComponent + 0.3 {
                    recorderPixels.append(x)
                }
            }
        }

        let labelMaxX = try XCTUnwrap(labelPixels.max())
        let recorderMinX = try XCTUnwrap(recorderPixels.min())
        let backingScale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        XCTAssertEqual(
            CGFloat(recorderMinX - labelMaxX - 1),
            PluginSettingsTheme.Spacing.controlCluster * backingScale,
            accuracy: backingScale
        )
    }

    private func row(id: String) -> PluginSettingsRow {
        PluginSettingsRow(id: id, title: id, control: .toggle(isOn: false))
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return 0
        }

        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }
}

private struct PluginSettingsCardSurfaceProbe: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Color.clear
                .frame(width: 140, height: 90)
                .pluginSettingsCardBackground(.standard)
        }
        .frame(width: 220, height: 140)
    }
}

private struct PluginSettingsShortcutLayoutProbe: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white

            PluginSettingsShortcutControlLayout {
                Color.red.frame(width: 60, height: 20)
                Color.blue.frame(
                    width: PluginSettingsTheme.Size.shortcutRecorderWidth,
                    height: 30
                )
            }
            .padding(10)
        }
        .frame(width: 320, height: 60)
    }
}
