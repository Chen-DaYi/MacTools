import XCTest
@testable import MacTools
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessPluginTests: XCTestCase {
    func testParseDisplayIDExtractsNumericIdentifier() {
        XCTAssertEqual(
            DisplayBrightnessPlugin.parseDisplayID(from: "display.42.brightness"),
            42
        )
    }

    func testParseDisplayIDRejectsUnexpectedControlID() {
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "display.42"))
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "brightness.42"))
        XCTAssertNil(DisplayBrightnessPlugin.parseDisplayID(from: "display.foo.brightness"))
    }

    func testEmptySnapshotDisablesPluginAndSuppressesDetail() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(displays: [], errorMessage: nil)

        let plugin = DisplayBrightnessPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let state = plugin.primaryPanelState

        XCTAssertEqual(state.subtitle, "未检测到可调节亮度的显示器")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isExpanded)
        XCTAssertNil(state.detail)
    }

    func testSingleDisplaySummaryIncludesDisplayNameAndBrightness() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "Studio Display 72%")
    }

    func testMultipleDisplaysSummaryUsesDisplayCount() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "2 个显示器")
    }

    func testExpandedStateBuildsOneSliderPerDisplay() throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)
        let sliders = controls.filter { $0.kind == .slider }

        XCTAssertEqual(sliders.count, 2)
        XCTAssertEqual(sliders.map(\.id), ["display.7.brightness", "display.9.brightness"])
        XCTAssertEqual(sliders.map(\.sectionTitle), ["Studio Display", "LG UltraFine"])
        XCTAssertEqual(sliders.map(\.valueLabel), ["72%", "41%"])
        XCTAssertEqual(sliders.first?.sliderBounds, 0...1)
        XCTAssertEqual(sliders.first?.sliderStep, 0.01)
    }

    func testShortcutDefinitionsIncludeDecreaseAndIncreaseOnly() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(
                    id: 7,
                    name: "Studio Display",
                    brightness: 0.72,
                    vendorNumber: 0x610,
                    modelNumber: 32,
                    serialNumber: 9001
                )
            ],
            errorMessage: nil
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)
        let definitions = plugin.shortcutDefinitions

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions.map(\.id), ["display-brightness.decrease", "display-brightness.increase"])
        XCTAssertEqual(definitions.map(\.title), ["降低亮度", "增加亮度"])
        XCTAssertEqual(definitions.map(\.description), ["降低显示器亮度。", "增加显示器亮度。"])
        XCTAssertEqual(definitions.map(\.settingsGroupTitle), ["亮度快捷键", "亮度快捷键"])
        XCTAssertEqual(
            definitions.map(\.settingsGroupDescription),
            [
                "按所选作用范围调整显示器亮度。",
                "按所选作用范围调整显示器亮度。"
            ]
        )
        XCTAssertEqual(definitions.map(\.settingsControlTitle), ["降低", "增加"])
        XCTAssertEqual(definitions.map(\.settingsControlSystemImage), ["sun.min.fill", "sun.max.fill"])
        XCTAssertEqual(definitions.map(\.settingsGroupID), ["display-brightness.shortcuts", "display-brightness.shortcuts"])
        XCTAssertEqual(definitions.map(\.sharedBindingGroupID), [nil, nil])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global])
    }

    func testShortcutPreferencesDefaultToFollowingMouse() {
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())

        XCTAssertEqual(preferences.targetMode, .followsMouse)
    }

    func testShortcutPreferencesPersistTargetMode() {
        let storage = DisplayBrightnessMemoryStorage()
        let preferences = DisplayBrightnessShortcutPreferences(storage: storage)

        preferences.targetMode = .allDisplays

        XCTAssertEqual(DisplayBrightnessShortcutPreferences(storage: storage).targetMode, .allDisplays)
    }

    func testShortcutDirectionResolvesFixedActionIDs() {
        XCTAssertEqual(
            DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.decrease"),
            .decrease
        )
        XCTAssertEqual(
            DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.increase"),
            .increase
        )
        XCTAssertNil(DisplayBrightnessPlugin.shortcutDirection(for: "display-brightness.display.7.increase"))
    }

    func testShortcutFollowingMouseAdjustsOnlyMouseDisplay() throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .followsMouse
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 1)
        let write = try XCTUnwrap(controller.brightnessWrites.first)
        XCTAssertEqual(write.displayID, 9)
        XCTAssertEqual(write.value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(write.phase, .changed)
    }

    func testShortcutAllDisplaysAdjustsEveryDisplay() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .allDisplays
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.decrease", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 2)
        XCTAssertEqual(controller.brightnessWrites.map(\.displayID), [7, 9])
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.changed, .changed])
        XCTAssertEqual(controller.brightnessWrites[0].value, 0.71, accuracy: 0.0001)
        XCTAssertEqual(controller.brightnessWrites[1].value, 0.40, accuracy: 0.0001)
    }

    func testErrorMessageIsExposedFromSnapshot() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)
            ],
            errorMessage: "调节失败：DDC 写入失败"
        )

        let plugin = DisplayBrightnessPlugin(controller: controller)

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "调节失败：DDC 写入失败")
    }
}
