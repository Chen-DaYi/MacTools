import XCTest
import MacToolsPluginKit
@testable import LockScreenPlugin

@MainActor
final class LockScreenPluginTests: XCTestCase {
    func testPluginContract() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.metadata.id, "lock-screen")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.commandDefinitions.count, 1)
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["execute"])
        XCTAssertEqual(plugin.actionDefinitions.first?.externalInvocationPolicy, .confirmAlways)
        XCTAssertNotNil(plugin.actionDefinitions.first?.confirmation)
    }

    func testRunLinkConfirmationUsesSelectedLanguage() throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("LockScreenTests.bundle", isDirectory: true)
        let languageURL = bundleURL.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
        try [
            "\"action.confirmation.title\" = \"Lock the Screen?\";",
            "\"action.confirmation.confirm\" = \"Lock\";",
        ].joined(separator: "\n").write(
            to: languageURL.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        PluginRuntimeLocalization.source.setPreference("en")
        let plugin = LockScreenPlugin(
            localization: PluginLocalization(bundle: try XCTUnwrap(Bundle(url: bundleURL)))
        )

        let confirmation = try XCTUnwrap(plugin.actionDefinitions.first?.confirmation)
        XCTAssertEqual(confirmation.title, "Lock the Screen?")
        XCTAssertEqual(confirmation.confirmButtonTitle, "Lock")
    }
}
