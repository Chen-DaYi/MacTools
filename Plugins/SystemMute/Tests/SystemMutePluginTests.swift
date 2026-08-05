import XCTest
import MacToolsPluginKit
@testable import SystemMutePlugin

@MainActor
final class SystemMutePluginTests: XCTestCase {
    private final class MockController: SystemAudioControlling {
        var muteState: Bool
        var setMuteResult: Bool

        init(muteState: Bool, setMuteResult: Bool = true) {
            self.muteState = muteState
            self.setMuteResult = setMuteResult
        }

        func readMuteState() -> Bool { muteState }
        func setMuteState(_ muted: Bool) -> Bool {
            if setMuteResult {
                muteState = muted
            }
            return setMuteResult
        }
    }

    func testPanelStateReflectsMuteState() {
        let unmuted = SystemMutePlugin(controller: MockController(muteState: false))
        let muted = SystemMutePlugin(controller: MockController(muteState: true))

        XCTAssertFalse(unmuted.primaryPanelState.isOn)
        XCTAssertEqual(unmuted.primaryPanelState.subtitle, "未静音")
        XCTAssertTrue(muted.primaryPanelState.isOn)
        XCTAssertEqual(muted.primaryPanelState.subtitle, "已静音")
    }

    func testSwitchUpdatesStateAndNotifiesHost() {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
        XCTAssertEqual(notificationCount, 1)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = SystemMutePlugin(
            controller: MockController(muteState: false, setMuteResult: false)
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testFailureRelocalizesAndClearsOnSamePluginInstance() async throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let (localization, directory) = try makeLocalization([
            "en": ["error.muteFailed": "Failed to mute audio."],
            "ar": ["error.muteFailed": "فشل كتم الصوت."],
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MockController(muteState: false, setMuteResult: false)
        let plugin = SystemMutePlugin(
            controller: controller,
            localization: localization
        )

        PluginRuntimeLocalization.source.setPreference("en")
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Failed to mute audio.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "فشل كتم الصوت.")
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let failure = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(failure, .failed(message: "فشل كتم الصوت."))

        controller.setMuteResult = true
        plugin.handleAction(.setSwitch(true))
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testRefreshDoesNotNotifyWhenStateIsUnchanged() {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.refresh()

        XCTAssertEqual(notificationCount, 0)
    }

    func testActionCatalogProvidesIdempotentMuteChoices() async throws {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["静音系统音频", "恢复系统音频"])
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    private func makeLocalization(
        _ valuesByLanguage: [String: [String: String]]
    ) throws -> (PluginLocalization, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("SystemMuteTests.bundle", isDirectory: true)
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
