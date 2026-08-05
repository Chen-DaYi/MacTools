import XCTest
import MacToolsPluginKit
@testable import NightShiftPlugin

@MainActor
final class NightShiftPluginTests: XCTestCase {
    private final class MockController: NightShiftControlling {
        var status: Bool
        var setEnabledResult: Bool

        init(status: Bool, setEnabledResult: Bool = true) {
            self.status = status
            self.setEnabledResult = setEnabledResult
        }

        func getStatus() -> Bool { status }
        func setEnabled(_ enabled: Bool) -> Bool {
            if setEnabledResult {
                status = enabled
            }
            return setEnabledResult
        }
    }

    func testPanelStateReflectsControllerStatus() {
        let disabled = NightShiftPlugin(controller: MockController(status: false))
        let enabled = NightShiftPlugin(controller: MockController(status: true))

        XCTAssertFalse(disabled.primaryPanelState.isOn)
        XCTAssertEqual(disabled.primaryPanelState.subtitle, "已关闭")
        XCTAssertTrue(enabled.primaryPanelState.isOn)
        XCTAssertEqual(enabled.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchUpdatesPanelState() {
        let plugin = NightShiftPlugin(controller: MockController(status: false))

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = NightShiftPlugin(
            controller: MockController(status: true, setEnabledResult: false)
        )

        plugin.handleAction(.setSwitch(false))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testFailureRelocalizesAndClearsOnSamePluginInstance() async throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let (localization, directory) = try makeLocalization([
            "en": ["error.toggleFailed": "Failed to toggle Night Shift."],
            "ar": ["error.toggleFailed": "فشل التبديل Night Shift."],
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MockController(status: false, setEnabledResult: false)
        let plugin = NightShiftPlugin(
            controller: controller,
            localization: localization
        )

        PluginRuntimeLocalization.source.setPreference("en")
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Failed to toggle Night Shift.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "فشل التبديل Night Shift.")
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let failure = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(failure, .failed(message: "فشل التبديل Night Shift."))

        controller.setEnabledResult = true
        plugin.handleAction(.setSwitch(true))
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testActionCatalogProvidesIdempotentNightShiftChoices() async throws {
        let plugin = NightShiftPlugin(controller: MockController(status: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["启用夜览", "停用夜览"])
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    private func makeLocalization(
        _ valuesByLanguage: [String: [String: String]]
    ) throws -> (PluginLocalization, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("NightShiftTests.bundle", isDirectory: true)
        for (language, values) in valuesByLanguage {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            try values.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .joined(separator: "\n")
                .write(
                    to: languageURL.appendingPathComponent("Localizable.strings"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return (
            PluginLocalization(bundle: try XCTUnwrap(Bundle(url: bundleURL))),
            directory
        )
    }
}
